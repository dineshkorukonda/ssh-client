import Config

if config_env() == :prod do
  port = String.to_integer(System.get_env("SSH_CLIENT_PORT") || "4000")
  config :ssh_client, SSHClientWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: port]
  config :ssh_client, :desktop_token, System.get_env("SSH_CLIENT_DESKTOP_TOKEN")
end
