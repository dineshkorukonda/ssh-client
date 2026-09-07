import Config

database_path =
  case System.get_env("SSH_CLIENT_DATABASE_PATH") do
    path when is_binary(path) and path != "" ->
      Path.expand(path)

    _ ->
      config_dir =
        case :filename.basedir(:user_config, "ssh-client") do
          dir when is_binary(dir) -> dir
          dir when is_list(dir) -> List.to_string(dir)
        end

      Path.join(config_dir, "terminal_workspaces.db")
  end

config :ssh_client,
  ecto_repos: [SSHClient.Repo]

config :ssh_client, SSHClient.Repo,
  database: database_path,
  pool_size: 5,
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
