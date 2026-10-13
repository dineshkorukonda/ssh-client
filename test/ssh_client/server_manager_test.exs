defmodule SSHClient.ServerManagerTest do
  use ExUnit.Case, async: false

  alias SSHClient.Config
  alias SSHClient.Config.Server
  alias SSHClient.ServerManager
  alias SSHClient.ServerSupervisor

  defp mock_runner(_server, :connect), do: {:ok, :fake_conn}
  defp mock_runner(_server, {:exec, _conn, _cmd}), do: {:ok, "systemd\n", 0}

  defp mock_runner(_server, {:poll, _conn, _checks}),
    do: {:ok, %{metrics: %{cpu: 10}, checks: %{}}}

  defp mock_runner(_server, {:close, _conn}), do: :ok

  setup do
    # Ensure supervisor and registry are active
    if Process.whereis(SSHClient.WorkerRegistry) == nil do
      start_supervised!({Registry, keys: :unique, name: SSHClient.WorkerRegistry})
    end

    {:ok, sup} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

    {:ok, manager} =
      start_supervised(
        {ServerManager, name: nil, supervisor: sup, runner: &mock_runner/2, poll_interval: 10_000}
      )

    %{manager: manager, supervisor: sup}
  end

  describe "sync_config/3" do
    test "starts workers for initial servers", %{manager: manager, supervisor: sup} do
      server_a = %Server{id: "server-a", host: "10.0.0.1"}
      server_b = %Server{id: "server-b", host: "10.0.0.2"}

      assert {:ok, result} = ServerManager.sync_config(manager, [server_a, server_b])
      assert result.added == ["server-a", "server-b"]
      assert result.removed == []
      assert result.total_active == 2

      assert ServerSupervisor.count_workers(sup) == 2

      workers = ServerManager.get_workers(manager)
      assert is_pid(workers["server-a"])
      assert is_pid(workers["server-b"])
      assert Process.alive?(workers["server-a"])
      assert Process.alive?(workers["server-b"])
    end

    test "adds new server without restarting existing workers", %{
      manager: manager,
      supervisor: sup
    } do
      server_a = %Server{id: "srv-a", host: "10.0.0.1"}
      server_b = %Server{id: "srv-b", host: "10.0.0.2"}

      {:ok, _} = ServerManager.sync_config(manager, [server_a, server_b])
      workers_before = ServerManager.get_workers(manager)
      pid_a_before = workers_before["srv-a"]
      pid_b_before = workers_before["srv-b"]

      # Add server-c
      server_c = %Server{id: "srv-c", host: "10.0.0.3"}
      assert {:ok, result} = ServerManager.sync_config(manager, [server_a, server_b, server_c])

      assert result.added == ["srv-c"]
      assert result.removed == []
      assert result.total_active == 3
      assert ServerSupervisor.count_workers(sup) == 3

      workers_after = ServerManager.get_workers(manager)
      # Existing workers must not restart (same pids)
      assert workers_after["srv-a"] == pid_a_before
      assert workers_after["srv-b"] == pid_b_before
      assert is_pid(workers_after["srv-c"])
    end

    test "removes server without restarting remaining workers", %{
      manager: manager,
      supervisor: sup
    } do
      server_a = %Server{id: "node-a", host: "10.0.0.1"}
      server_b = %Server{id: "node-b", host: "10.0.0.2"}
      server_c = %Server{id: "node-c", host: "10.0.0.3"}

      {:ok, _} = ServerManager.sync_config(manager, [server_a, server_b, server_c])
      workers_before = ServerManager.get_workers(manager)
      pid_a_before = workers_before["node-a"]
      pid_b_before = workers_before["node-b"]
      pid_c_before = workers_before["node-c"]

      # Remove node-b
      assert {:ok, result} = ServerManager.sync_config(manager, [server_a, server_c])

      assert result.added == []
      assert result.removed == ["node-b"]
      assert result.total_active == 2
      assert ServerSupervisor.count_workers(sup) == 2

      workers_after = ServerManager.get_workers(manager)
      assert workers_after["node-a"] == pid_a_before
      assert workers_after["node-c"] == pid_c_before
      refute Map.has_key?(workers_after, "node-b")

      # Removed worker process should no longer be alive
      refute Process.alive?(pid_b_before)
    end
  end

  describe "sync_file/3" do
    test "loads from file path and reconciles servers", %{manager: manager} do
      yaml_v1 = """
      servers:
        - id: file-server-1
          host: 192.168.1.50
      """

      path =
        Path.join(
          System.tmp_dir!(),
          "servers_sync_test_#{System.unique_integer([:positive])}.yaml"
        )

      File.write!(path, yaml_v1)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, result1} = ServerManager.sync_file(manager, path)
      assert result1.added == ["file-server-1"]

      # Update file with added server-2 and removed server-1
      yaml_v2 = """
      servers:
        - id: file-server-2
          host: 192.168.1.51
      """

      File.write!(path, yaml_v2)

      assert {:ok, result2} = ServerManager.sync_file(manager, path)
      assert result2.added == ["file-server-2"]
      assert result2.removed == ["file-server-1"]
    end
  end

  describe "list_servers/1 and get_server/2" do
    test "returns snapshots of running servers", %{manager: manager} do
      server_a = %Server{id: "srv-inspect", host: "10.0.0.10"}
      {:ok, _} = ServerManager.sync_config(manager, [server_a])

      # Allow initial connect and poll
      Process.sleep(50)

      servers = ServerManager.list_servers(manager)
      assert length(servers) == 1
      [snapshot] = servers
      assert snapshot.id == "srv-inspect"
      assert snapshot.status == :polling

      assert {:ok, single} = ServerManager.get_server(manager, "srv-inspect")
      assert single.id == "srv-inspect"

      assert {:error, :not_found} = ServerManager.get_server(manager, "unknown-id")
    end
  end

  describe "add_server/3 and remove_server/2" do
    test "dynamically adds and removes server workers and persists changes", %{
      manager: manager,
      supervisor: sup
    } do
      config_file =
        Path.join(
          System.tmp_dir!(),
          "manager_add_remove_test_#{System.unique_integer([:positive])}.yaml"
        )

      File.write!(config_file, "servers: []\n")
      on_exit(fn -> File.rm(config_file) end)

      # Initialize manager config path
      ServerManager.sync_file(manager, config_file)

      server_map = %{
        "id" => "dyn-srv-1",
        "name" => "Dynamic Server 1",
        "host" => "192.168.1.20",
        "port" => 22
      }

      assert {:ok, result} = ServerManager.add_server(manager, server_map)
      assert result.id == "dyn-srv-1"
      assert result.status == "started"

      # Worker is running
      workers = ServerManager.get_workers(manager)
      assert Map.has_key?(workers, "dyn-srv-1")
      assert ServerSupervisor.count_workers(sup) >= 1

      # File was written
      assert {:ok, file_cfg} = Config.load_file(config_file)
      assert length(file_cfg.servers) == 1
      assert hd(file_cfg.servers).id == "dyn-srv-1"

      # Remove server
      assert {:ok, rem_result} = ServerManager.remove_server(manager, "dyn-srv-1")
      assert rem_result.id == "dyn-srv-1"
      assert rem_result.status == "removed"

      workers_after = ServerManager.get_workers(manager)
      refute Map.has_key?(workers_after, "dyn-srv-1")

      # File was updated
      assert {:ok, updated_cfg} = Config.load_file(config_file)
      assert updated_cfg.servers == []
    end

    test "removes server from config file even if its worker is not active", %{
      manager: manager
    } do
      config_file =
        Path.join(
          System.tmp_dir!(),
          "manager_inactive_test_#{System.unique_integer([:positive])}.yaml"
        )

      on_exit(fn -> File.rm(config_file) end)

      server = %Server{id: "orphan-srv", host: "10.0.0.99"}
      Config.save_file([server], config_file)

      # Server is in config file but not in manager workers
      workers = ServerManager.get_workers(manager)
      refute Map.has_key?(workers, "orphan-srv")

      # Remove should succeed and remove it from config
      original = System.get_env("SSH_CLIENT_SERVERS_CONFIG")
      System.put_env("SSH_CLIENT_SERVERS_CONFIG", config_file)

      try do
        assert {:ok, rem_result} = ServerManager.remove_server(manager, "orphan-srv")
        assert rem_result.id == "orphan-srv"
        assert rem_result.status == "removed"

        assert {:ok, updated_cfg} = Config.load_file(config_file)
        assert updated_cfg.servers == []
      after
        if original,
          do: System.put_env("SSH_CLIENT_SERVERS_CONFIG", original),
          else: System.delete_env("SSH_CLIENT_SERVERS_CONFIG")
      end
    end
  end
end
