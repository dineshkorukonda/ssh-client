# Standalone local SSH target for testing the packaged native client.
[root] = System.argv()
File.mkdir_p!(root)
key = Path.expand("test/fixtures/docker/ssh-target/id_ed25519")
File.cp!(key, Path.join(root, "ssh_host_ed25519_key"))
File.cp!(key <> ".pub", Path.join(root, "authorized_keys"))
:ssh.start()
echo = fn echo ->
  case IO.gets("") do
    :eof -> :ok
    {:error, _} -> :ok
    line -> IO.puts("echo:" <> String.trim(to_string(line))); echo.(echo)
  end
end
{:ok, daemon} = :ssh.daemon({127, 0, 0, 1}, 0,
  system_dir: String.to_charlist(root), user_dir: String.to_charlist(root),
  auth_methods: ~c"publickey,password", pwdfun: fn user, password -> user == ~c"fixture" and password == ~c"fixture-password" end,
  shell: fn _user, _peer -> spawn(fn -> IO.puts("fixture-ready"); echo.(echo) end) end,
  subsystems: [:ssh_sftpd.subsystem_spec(cwd: String.to_charlist(root), root: String.to_charlist(root))])
{:ok, info} = :ssh.daemon_info(daemon)
port = Keyword.fetch!(info, :port)
[type, public_key | _] = String.split(File.read!(key <> ".pub"))
File.write!(Path.join(root, "known_hosts"), "[127.0.0.1]:#{port} #{type} #{public_key}\n")
File.write!(Path.join(root, "port"), Integer.to_string(port))
Process.sleep(:infinity)
