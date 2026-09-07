defmodule SSHClient.SessionWorkerTest do
  use ExUnit.Case, async: true

  alias SSHClient.Config.Server
  alias SSHClient.SessionWorker

  setup do
    session_id = "sess_test_#{System.unique_integer([:positive])}"
    server = %Server{
      id: "srv_test",
      host: "127.0.0.1",
      port: 2222,
      user: "testuser"
    }

    %{session_id: session_id, server: server}
  end

  describe "initialization and state machine" do
    test "initializes in disconnected state when auto_connect: false", %{
      session_id: session_id,
      server: server
    } do
      {:ok, pid} =
        SessionWorker.start_link(
          session_id: session_id,
          server: server,
          auto_connect: false
        )

      assert SessionWorker.get_status(pid) == :disconnected
      assert is_pid(pid)
    end

    test "initializes in connecting state when auto_connect: true without blocking", %{
      session_id: session_id,
      server: server
    } do
      {:ok, pid} =
        SessionWorker.start_link(
          session_id: session_id,
          server: server,
          auto_connect: true
        )

      status = SessionWorker.get_status(pid)
      assert status in [:connecting, :reconnecting, :error]
    end

    test "supports manual disconnect and reconnect transitions", %{
      session_id: session_id,
      server: server
    } do
      {:ok, pid} =
        SessionWorker.start_link(
          session_id: session_id,
          server: server,
          auto_connect: false
        )

      assert SessionWorker.get_status(pid) == :disconnected

      :ok = SessionWorker.disconnect(pid)
      assert SessionWorker.get_status(pid) == :disconnected

      :ok = SessionWorker.reconnect(pid)
      status = SessionWorker.get_status(pid)
      assert status in [:connecting, :reconnecting, :error]
    end
  end

  describe "pubsub output and notifications" do
    test "broadcasts status updates to Phoenix.PubSub", %{
      session_id: session_id,
      server: server
    } do
      topic = "ssh_client:session:#{session_id}"
      Phoenix.PubSub.subscribe(SSHClient.PubSub, topic)

      {:ok, pid} =
        SessionWorker.start_link(
          session_id: session_id,
          server: server,
          auto_connect: false
        )

      :ok = SessionWorker.reconnect(pid)

      assert_receive {:session_status, ^session_id, status}, 1000
      assert status in [:connecting, :reconnecting, :error]
    end

    test "broadcasts pty_output when data arrives", %{
      session_id: session_id,
      server: server
    } do
      topic = "ssh_client:session:#{session_id}"
      Phoenix.PubSub.subscribe(SSHClient.PubSub, topic)

      {:ok, pid} =
        SessionWorker.start_link(
          session_id: session_id,
          server: server,
          auto_connect: false
        )

      # Inject simulated pty data directly into worker
      send(pid, {:simulate_data, "hello world\r\n"})

      assert_receive {:pty_output, ^session_id, "hello world\r\n"}, 1000
      snapshot = SessionWorker.get_buffer(pid)
      assert String.contains?(snapshot.text, "hello world")
    end
  end

  describe "ring buffer and snapshot" do
    test "retrieves initial buffer snapshot and handles input/resizing", %{
      session_id: session_id,
      server: server
    } do
      {:ok, pid} =
        SessionWorker.start_link(
          session_id: session_id,
          server: server,
          auto_connect: false,
          cols: 80,
          rows: 24
        )

      snapshot = SessionWorker.get_buffer(pid)
      assert is_map(snapshot)
      assert snapshot.cols == 80
      assert snapshot.rows == 24
      assert is_binary(snapshot.text)

      :ok = SessionWorker.resize(pid, 120, 40)
      resized = SessionWorker.get_buffer(pid)
      assert resized.cols == 120
      assert resized.rows == 40

      :ok = SessionWorker.send_input(pid, "ls -la\n")
    end
  end

  describe "client independence" do
    test "worker does not terminate when caller or listener exits", %{
      session_id: session_id,
      server: server
    } do
      {:ok, pid} =
        SessionWorker.start_link(
          session_id: session_id,
          server: server,
          auto_connect: false
        )

      task =
        Task.async(fn ->
          Phoenix.PubSub.subscribe(SSHClient.PubSub, "ssh_client:session:#{session_id}")
          SessionWorker.get_buffer(pid)
          :done
        end)

      assert Task.await(task) == :done

      # Worker must remain alive!
      assert Process.alive?(pid)
      assert SessionWorker.get_status(pid) == :disconnected
    end
  end
end
