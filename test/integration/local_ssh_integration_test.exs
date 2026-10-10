defmodule SSHClient.Integration.LocalSSHIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias SSHClient.SSH
  alias SSHClient.SSH.HostKeyVerifier
  alias SSHClient.SessionWorker
  alias SSHClient.Config.Server

  setup do
    root = Path.join(System.tmp_dir!(), "ssh-fixture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    identity = Path.join(root, "selected-cloud-key")
    File.cp!("test/fixtures/docker/ssh-target/id_ed25519", identity)
    File.cp!(identity, Path.join(root, "ssh_host_ed25519_key"))
    File.cp!("test/fixtures/docker/ssh-target/id_ed25519.pub", Path.join(root, "authorized_keys"))

    shell = fn _user, _peer ->
      spawn(fn ->
        IO.puts("fixture-ready")
        echo_loop()
      end)
    end

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        system_dir: String.to_charlist(root),
        user_dir: String.to_charlist(root),
        auth_methods: ~c"publickey,password",
        user_passwords: [{~c"fixture", ~c"secret"}],
        shell: shell,
        exec: {:direct, fn command -> {:ok, "executed:" <> to_string(command)} end},
        tcpip_tunnel_in: true,
        tcpip_tunnel_out: true,
        subsystems: [
          :ssh_sftpd.subsystem_spec(cwd: String.to_charlist(root), root: String.to_charlist(root))
        ]
      )

    {:ok, info} = :ssh.daemon_info(daemon)
    port = Keyword.fetch!(info, :port)
    server = %Server{id: "local-#{port}", host: "127.0.0.1", port: port, user: "fixture"}
    known_hosts = Path.join(root, "known_hosts")
    opts = [identity_file: identity, known_hosts_file: known_hosts, timeout: 3000]

    on_exit(fn ->
      :ssh.stop_daemon(daemon)
      File.rm_rf(root)
    end)

    %{server: server, opts: opts, root: root, known_hosts: known_hosts}
  end

  defp echo_loop do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        IO.puts("echo:" <> String.trim(to_string(line)))
        echo_loop()
    end
  end

  defp approve(server, opts) do
    assert {:error, _} = SSH.connect(server, Keyword.put(opts, :host_key_handler, self()))
    assert_receive {:ssh_host_key_event, :first_connect, details}, 3000
    assert :ok = HostKeyVerifier.save_host_key(details.host, details.port, details.key, opts)
  end

  test "first-use trust, custom identity, remote execution and SFTP round trip", %{
    server: server,
    opts: opts
  } do
    approve(server, opts)
    assert {:ok, conn} = SSH.connect(server, opts)

    try do
      assert {:ok, output, 0} = SSH.exec(conn, "baseline", timeout: 3000)
      assert output =~ "executed:baseline"
      assert {:ok, channel} = :ssh_sftp.start_channel(conn.conn_ref)
      assert :ok = :ssh_sftp.write_file(channel, ~c"roundtrip.txt", "transfer content")
      assert {:ok, "transfer content"} = :ssh_sftp.read_file(channel, ~c"roundtrip.txt")
      :ssh_sftp.stop_channel(channel)
    after
      SSH.close(conn)
    end
  end

  test "password authentication works and wrong credentials fail", %{server: server, opts: opts} do
    approve(server, opts)

    password_opts =
      opts |> Keyword.delete(:identity_file) |> Keyword.put(:auth_order, [:password])

    assert {:ok, conn} = SSH.connect(server, Keyword.put(password_opts, :password, "secret"))
    SSH.close(conn)
    assert {:error, _} = SSH.connect(server, Keyword.put(password_opts, :password, "wrong"))
  end

  test "changed keys remain blocked and never enter automatic retries", %{
    server: server,
    opts: opts
  } do
    assert :ok = HostKeyVerifier.save_host_key(server.host, server.port, "different-key", opts)
    id = "untrusted-#{server.port}"
    Phoenix.PubSub.subscribe(SSHClient.PubSub, "ssh_client:session:#{id}")
    worker = start_supervised!({SessionWorker, session_id: id, server: server, ssh_opts: opts})
    assert_receive {:ssh_host_key_event, ^id, :host_key_changed, _}, 5000
    assert_receive {:session_status, ^id, :error}, 5000
    assert :sys.get_state(worker).reconnect_timer == nil
  end

  test "session owns PTY output, supports input and resize, and disconnect cleans up", %{
    server: server,
    opts: opts
  } do
    approve(server, opts)
    id = "fixture-session-#{server.port}"
    Phoenix.PubSub.subscribe(SSHClient.PubSub, "ssh_client:session:#{id}")
    worker = start_supervised!({SessionWorker, session_id: id, server: server, ssh_opts: opts})
    assert_receive {:session_status, ^id, :connected}, 5000
    assert_receive {:pty_output, ^id, _}, 3000
    assert :ok = SessionWorker.resize(worker, 120, 40)
    assert :ok = SessionWorker.send_input(worker, "hello\r")
    wait_output(id, "echo:hello", "")
    task = :sys.get_state(worker).connect_task
    monitor = Process.monitor(task)
    assert :ok = SessionWorker.disconnect(worker)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}, 3000
    assert SessionWorker.get_status(worker) == :disconnected
  end

  test "bastion uses separate credentials and preserves destination trust", %{
    server: server,
    opts: opts
  } do
    approve(server, opts)
    target = %{server | proxy_jump: "fixture@127.0.0.1:#{server.port}"}

    jump_opts = [
      password: "secret",
      auth_order: [:password],
      known_hosts_file: opts[:known_hosts_file]
    ]

    assert {:ok, conn} = SSH.connect(target, Keyword.put(opts, :jump_opts, jump_opts))
    assert conn.jump_ref != nil
    assert {:ok, output, 0} = SSH.exec(conn, "through-bastion", timeout: 3000)
    assert output =~ "through-bastion"
    SSH.close(conn)
  end

  defp wait_output(id, expected, acc) do
    if String.contains?(acc, expected) do
      :ok
    else
      receive do
        {:pty_output, ^id, data} -> wait_output(id, expected, acc <> data)
      after
        3000 -> flunk("PTY output missing #{inspect(expected)}; received #{inspect(acc)}")
      end
    end
  end
end
