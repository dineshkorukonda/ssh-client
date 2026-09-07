import Config

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
