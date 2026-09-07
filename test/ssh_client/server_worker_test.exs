defmodule SSHClient.ServerWorkerTest do
  use ExUnit.Case, async: false

  alias SSHClient.Config.Server
  alias SSHClient.ServerWorker

  @test_server %Server{
    id: "test-node-1",
    name: "Test Node 1",
    host: "127.0.0.1",
    port: 22,
    checks: []
  }

  setup do
    if Process.whereis(SSHClient.WorkerRegistry) == nil do
      start_supervised!({Registry, keys: :unique, name: SSHClient.WorkerRegistry})
    end

    :ok
  end

  describe "state machine transitions" do
    test "transitions from connecting to polling on successful connection" do
      test_pid = self()

      mock_runner = fn
        _server, :connect ->
          send(test_pid, :connected)
          {:ok, :fake_conn}

        _server, {:exec, _conn, _cmd} ->
          {:ok, "systemd\n", 0}

        _server, {:poll, _conn, _checks} ->
          send(test_pid, :polled)
          {:ok, %{metrics: %{cpu: 15}, checks: %{}}}

        _server, {:close, _conn} ->
          :ok
      end

      {:ok, worker} =
        ServerWorker.start_link(@test_server,
          runner: mock_runner,
          name: nil,
          poll_interval: 10_000
        )

      assert_receive :connected, 1000
      assert_receive :polled, 1000

      assert ServerWorker.get_status(worker) == :polling

      state = ServerWorker.get_state(worker)
      assert state.status == :polling
      assert state.init_system == :systemd
      assert state.metrics == %{cpu: 15}
    end

    test "transitions from polling to degraded on check degradation" do
      mock_runner = fn
        _server, :connect ->
          {:ok, :fake_conn}

        _server, {:exec, _conn, _cmd} ->
          {:ok, "systemd\n", 0}

        _server, {:poll, _conn, _checks} ->
          {:degraded, :service_unhealthy, %{checks: %{"nginx" => :stopped}}}

        _server, {:close, _conn} ->
          :ok
      end

      {:ok, worker} =
        ServerWorker.start_link(@test_server,
          runner: mock_runner,
          name: nil,
          poll_interval: 10_000
        )

      # Allow initial connect and poll
      Process.sleep(50)

      assert ServerWorker.get_status(worker) == :degraded
      state = ServerWorker.get_state(worker)
      assert state.status == :degraded
      assert state.last_error == :service_unhealthy
    end

    test "transitions to reconnecting on connection failure during connect" do
      mock_runner = fn
        _server, :connect ->
          {:error, :econnrefused}

        _server, {:close, _conn} ->
          :ok
      end

      {:ok, worker} =
        ServerWorker.start_link(@test_server,
          runner: mock_runner,
          name: nil,
          reconnect_interval: 10_000
        )

      Process.sleep(50)

      assert ServerWorker.get_status(worker) == :reconnecting
      assert ServerWorker.get_state(worker).last_error == :econnrefused
    end

    test "transitions to reconnecting on connection loss during polling" do
      mock_runner = fn
        _server, :connect ->
          {:ok, :fake_conn}

        _server, {:exec, _conn, _cmd} ->
          {:ok, "systemd\n", 0}

        _server, {:poll, _conn, _checks} ->
          {:error, :connection_lost}

        _server, {:close, _conn} ->
          :ok
      end

      {:ok, worker} =
        ServerWorker.start_link(@test_server,
          runner: mock_runner,
          name: nil,
          poll_interval: 10_000
        )

      Process.sleep(50)

      assert ServerWorker.get_status(worker) == :reconnecting
    end

    test "reconnects successfully after reconnect interval" do
      connect_attempts = :counters.new(1, [:atomics])

      mock_runner = fn
        _server, :connect ->
          count = :counters.get(connect_attempts, 1)
          :counters.add(connect_attempts, 1, 1)

          if count == 0 do
            {:error, :econnrefused}
          else
            {:ok, :fake_conn}
          end

        _server, {:exec, _conn, _cmd} ->
          {:ok, "systemd\n", 0}

        _server, {:poll, _conn, _checks} ->
          {:ok, %{metrics: %{}, checks: %{}}}

        _server, {:close, _conn} ->
          :ok
      end

      {:ok, worker} =
        ServerWorker.start_link(@test_server,
          runner: mock_runner,
          name: nil,
          reconnect_interval: 300,
          poll_interval: 10_000
        )

      Process.sleep(50)
      assert ServerWorker.get_status(worker) == :reconnecting

      # Wait for reconnect_interval (300ms)
      Process.sleep(400)
      assert ServerWorker.get_status(worker) == :polling
    end

    test "poll_now triggers immediate poll" do
      mock_runner = fn
        _server, :connect -> {:ok, :fake_conn}
        _server, {:exec, _conn, _cmd} -> {:ok, "systemd\n", 0}
        _server, {:poll, _conn, _checks} -> {:ok, %{metrics: %{cpu: 50}, checks: %{}}}
        _server, {:close, _conn} -> :ok
      end

      {:ok, worker} =
        ServerWorker.start_link(@test_server,
          runner: mock_runner,
          name: nil,
          poll_interval: 60_000
        )

      Process.sleep(50)
      assert {:ok, :polling} = ServerWorker.poll_now(worker)
      assert ServerWorker.get_state(worker).metrics == %{cpu: 50}
    end

    test "reconnect forces reconnection" do
      mock_runner = fn
        _server, :connect -> {:ok, :fake_conn}
        _server, {:exec, _conn, _cmd} -> {:ok, "systemd\n", 0}
        _server, {:poll, _conn, _checks} -> {:ok, %{metrics: %{}, checks: %{}}}
        _server, {:close, _conn} -> :ok
      end

      {:ok, worker} =
        ServerWorker.start_link(@test_server,
          runner: mock_runner,
          name: nil,
          poll_interval: 60_000
        )

      Process.sleep(50)
      assert :ok = ServerWorker.reconnect(worker)
      assert ServerWorker.get_status(worker) == :polling
    end
  end

  describe "supervisor isolation" do
    test "crashing worker does not affect other workers under supervisor" do
      mock_runner = fn
        _server, :connect -> {:ok, :fake_conn}
        _server, {:exec, _conn, _cmd} -> {:ok, "systemd\n", 0}
        _server, {:poll, _conn, _checks} -> {:ok, %{metrics: %{}, checks: %{}}}
        _server, {:close, _conn} -> :ok
      end

      server_a = %Server{id: "server-a", host: "10.0.0.1"}
      server_b = %Server{id: "server-b", host: "10.0.0.2"}

      # Start dynamic supervisor
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

      {:ok, worker_a} =
        DynamicSupervisor.start_child(
          sup,
          {ServerWorker, {server_a, runner: mock_runner, poll_interval: 10_000}}
        )

      {:ok, worker_b} =
        DynamicSupervisor.start_child(
          sup,
          {ServerWorker, {server_b, runner: mock_runner, poll_interval: 10_000}}
        )

      Process.sleep(50)

      assert ServerWorker.get_status(worker_a) == :polling
      assert ServerWorker.get_status(worker_b) == :polling

      # Forcefully kill worker_a
      Process.unlink(worker_a)
      Process.exit(worker_a, :kill)

      Process.sleep(50)

      # worker_b remains alive and healthy
      assert Process.alive?(worker_b)
      assert ServerWorker.get_status(worker_b) == :polling

      # worker_a was restarted by the DynamicSupervisor under the registry
      restarted_worker_a = ServerWorker.whereis("server-a")
      assert is_pid(restarted_worker_a)
      assert restarted_worker_a != worker_a
      assert Process.alive?(restarted_worker_a)
    end

    test "set_focus toggles focused? state on worker" do
      mock_runner = fn
        _server, :connect -> {:ok, :fake_conn}
        _server, {:exec, _conn, _cmd} -> {:ok, "systemd\n", 0}
        _server, {:poll, _conn, _checks} -> {:ok, %{metrics: %{}, checks: %{}}}
        _server, {:close, _conn} -> :ok
      end

      {:ok, worker} =
        ServerWorker.start_link(@test_server,
          runner: mock_runner,
          name: nil,
          poll_interval: 10_000
        )

      assert :ok = ServerWorker.set_focus(worker, false)
      assert :ok = ServerWorker.set_focus(worker, true)
    end
  end
end
