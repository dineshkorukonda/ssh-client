import Config

config :ssh_client,
  ecto_repos: [SSHClient.Repo]

config :ssh_client, SSHClient.Repo,
  pool_size: 1,
  journal_mode: :wal,
  foreign_keys: :on

config :ssh_client, SSHClientWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  secret_key_base: "sshclientdevkeybase0000000000000000000000000000000000000000000000",
  live_view: [signing_salt: "sshclientlv"],
  render_errors: [
    formats: [html: SSHClientWeb.ErrorHTML],
    layout: false
  ]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
