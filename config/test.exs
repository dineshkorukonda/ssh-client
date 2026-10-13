import Config

# The application starts before test_helper; isolate all user storage here.
test_config_dir =
  Path.join(
    System.tmp_dir!(),
    "ssh-client-test-#{System.unique_integer([:positive])}-#{System.os_time(:microsecond)}"
  )

System.put_env("SSH_CLIENT_SERVERS_CONFIG", Path.join(test_config_dir, "servers.json"))

config :ssh_client,
  config_dir: test_config_dir,
  ssh_home: test_config_dir,
  keychain_backend: :memory

test_database =
  Path.join(
    System.tmp_dir!(),
    "ssh_client_test_#{System.os_time(:microsecond)}_#{System.unique_integer([:positive])}.db"
  )

config :ssh_client, SSHClient.Repo,
  database: test_database,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1,
  journal_mode: :delete

config :ssh_client, SSHClientWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "sshclienttestkeybase0000000000000000000000000000000000000000000000",
  live_view: [signing_salt: "sshclientlv"],
  server: false

config :logger, level: :warning
