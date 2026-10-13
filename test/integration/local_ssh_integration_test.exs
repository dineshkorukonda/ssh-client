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
        auth_methods: ~c"publickey,password,keyboard-interactive",
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
    opts = [identity_file: identity, known_hosts_file: known_hosts, timeout: 10_000]

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
    jump_monitor = Process.monitor(conn.jump_ref)
    tunnel_monitor = Process.monitor(conn.jump_tunnel)

    try do
      assert {:ok, output, 0} = SSH.exec(conn, "through-bastion", timeout: 3000)
      assert output =~ "through-bastion"
      assert {:ok, channel} = :ssh_sftp.start_channel(conn.conn_ref)

      try do
        # Cross the SSH window boundary to detect forwarding that stalls after its first packets.
        payload = :binary.copy("bastion-stream", 180_000)
        assert :ok = :ssh_sftp.write_file(channel, ~c"bastion-roundtrip.txt", payload)
        assert {:ok, ^payload} = :ssh_sftp.read_file(channel, ~c"bastion-roundtrip.txt")
      after
        :ssh_sftp.stop_channel(channel)
      end
    after
      SSH.close(conn)
    end

    assert_receive {:DOWN, ^jump_monitor, :process, _, _}, 3000
    assert_receive {:DOWN, ^tunnel_monitor, :process, _, :normal}, 3000
  end

  test "desktop two-hop login forwards distinct bastion and destination credentials", %{
    server: server,
    opts: opts,
    root: root
  } do
    approve(server, opts)

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        system_dir: String.to_charlist(root),
        user_dir: String.to_charlist(root),
        auth_methods: ~c"password",
        tcpip_tunnel_in: true,
        tcpip_tunnel_out: true,
        pwdfun: fn user, password -> user == ~c"bastion" and password == ~c"bastion-secret" end
      )

    {:ok, info} = :ssh.daemon_info(daemon)
    jump = %{server | port: Keyword.fetch!(info, :port), user: "bastion"}
    previous = Application.get_env(:ssh_client, :desktop_known_hosts_file)

    on_exit(fn ->
      :ssh.stop_daemon(daemon)

      if previous,
        do: Application.put_env(:ssh_client, :desktop_known_hosts_file, previous),
        else: Application.delete_env(:ssh_client, :desktop_known_hosts_file)
    end)

    approve(jump, opts)
    Application.put_env(:ssh_client, :desktop_known_hosts_file, opts[:known_hosts_file])

    attrs = %{
      "host" => server.host,
      "port" => server.port,
      "user" => "fixture",
      "password" => "secret",
      "default_auth_method" => "password",
      "auth_order" => ["password"],
      "proxy_jump" => "wrong-user@127.0.0.1:#{jump.port}",
      "jump_credentials" => %{"user" => "bastion", "password" => "bastion-secret"}
    }

    assert {:ok, id} = SSHClient.Desktop.open_session(attrs)
    on_exit(fn -> SSHClient.SessionManager.close_session(id) end)
    {:ok, worker} = SSHClient.SessionManager.get_session(id)
    wait_connected(worker, 250)
    Phoenix.PubSub.subscribe(SSHClient.PubSub, "ssh_client:session:#{id}")

    assert :ok =
             SSHClient.Desktop.session_action(id, "input", %{"data" => "distinct-credentials\r"})

    wait_output(id, "echo:distinct-credentials", "")
    target = %{server | proxy_jump: attrs["proxy_jump"]}

    bad_opts = [
      known_hosts_file: opts[:known_hosts_file],
      password: "secret",
      auth_order: [:password],
      jump_opts: [user: "bastion", password: "secret", auth_order: [:password]],
      timeout: 3000
    ]

    assert {:error, {:jump_host_failed, _}} = SSH.connect(target, bad_opts)
  end

  defp wait_connected(_worker, 0), do: flunk("Two-hop desktop session did not connect")

  defp wait_connected(worker, remaining) do
    case SessionWorker.get_status(worker) do
      :connected ->
        :ok

      :error ->
        flunk(
          "Two-hop desktop connection failed: #{inspect(SessionWorker.desktop_snapshot(worker))}"
        )

      _ ->
        Process.sleep(20)
        wait_connected(worker, remaining - 1)
    end
  end

  test "native desktop sessions expose terminal events, approve trust and share SFTP", %{
    server: server,
    opts: opts
  } do
    assert {:ok, id} = SSHClient.SessionManager.create_session(server, ssh_opts: opts)
    on_exit(fn -> SSHClient.SessionManager.close_session(id) end)
    {:ok, worker} = SSHClient.SessionManager.get_session(id)
    monitor = Process.monitor(worker)
    Phoenix.PubSub.subscribe(SSHClient.PubSub, "ssh_client:session:#{id}")
    wait_prompt(worker, 100)
    assert {:ok, %{host_key_prompt: %{details: details}}} = SSHClient.Desktop.session(id, 0)
    refute Map.has_key?(details, :key)
    refute Map.has_key?(details, :known_hosts_file)
    assert :ok = SSHClient.Desktop.session_action(id, "trust", %{})
    assert_receive {:session_status, ^id, :connected}, 5000
    assert :ok = SSHClient.Desktop.session_action(id, "input", %{"data" => "native\r"})
    wait_output(id, "echo:native", "")
    assert {:ok, snapshot} = SSHClient.Desktop.session(id, 0)
    assert Enum.any?(snapshot.output, fn chunk -> Base.decode64!(chunk.data) =~ "native" end)

    assert {:ok, []} =
             SSHClient.Desktop.session(id, snapshot.cursor)
             |> then(fn {:ok, data} -> {:ok, data.output} end)

    local = Path.join(System.tmp_dir!(), "native-transfer-#{server.port}.txt")
    File.write!(local, "native transfer")
    on_exit(fn -> File.rm(local) end)

    assert :ok =
             SSHClient.Desktop.files(id, "upload", %{
               "local_path" => local,
               "path" => "native.txt"
             })

    assert {:ok, entries} = SSHClient.Desktop.files(id, "list", %{"path" => "."})
    assert Enum.any?(entries, &(&1.name == "native.txt"))
    assert :ok = SSHClient.SessionManager.close_session(id)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 3000
  end

  test "native keyboard-interactive prompts accept scoped answers without console IO", %{
    server: server,
    opts: opts
  } do
    approve(server, opts)
    id = "interactive-#{server.port}"

    opts =
      opts |> Keyword.delete(:identity_file) |> Keyword.put(:auth_order, [:keyboard_interactive])

    Phoenix.PubSub.subscribe(SSHClient.PubSub, "ssh_client:session:#{id}")
    worker = start_supervised!({SessionWorker, session_id: id, server: server, ssh_opts: opts})
    prompt = wait_auth_prompt(worker, 150)
    assert [%{echo: false}] = prompt.prompts

    assert {:error, :no_auth_prompt} =
             SessionWorker.answer_auth(worker, "stale-challenge", ["secret"])

    assert :ok = SessionWorker.answer_auth(worker, prompt.challenge, ["secret"])
    assert_receive {:session_status, ^id, :connected}, 5000
    assert SessionWorker.desktop_snapshot(worker).auth_prompt == nil
  end

  defp wait_auth_prompt(_worker, 0), do: flunk("Authentication prompt missing")

  defp wait_auth_prompt(worker, n) do
    case SessionWorker.desktop_snapshot(worker).auth_prompt do
      nil ->
        Process.sleep(20)
        wait_auth_prompt(worker, n - 1)

      prompt ->
        prompt
    end
  end

  defp wait_prompt(_worker, 0), do: flunk("Native trust prompt was not delivered")

  defp wait_prompt(worker, remaining) do
    case SessionWorker.desktop_snapshot(worker).host_key_prompt do
      nil ->
        Process.sleep(20)
        wait_prompt(worker, remaining - 1)

      _ ->
        :ok
    end
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
