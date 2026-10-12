import Config

if config_env() == :prod do
  port = String.to_integer(System.get_env("SSH_CLIENT_PORT") || "4000")

  address =
    if System.get_env("SSH_CLIENT_DESKTOP") == "1",
      do: "127.0.0.1",
      else: System.get_env("SSH_CLIENT_BIND_IP") || "127.0.0.1"

  {:ok, ip} = :inet.parse_address(String.to_charlist(address))

  config :ssh_client, SSHClientWeb.Endpoint,
    http: [ip: ip, port: port],
    secret_key_base:
      System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

  config :ssh_client, :desktop_token, System.get_env("SSH_CLIENT_DESKTOP_TOKEN")
  config :ssh_client, :desktop_known_hosts_file, System.get_env("SSH_CLIENT_KNOWN_HOSTS_FILE")
end
