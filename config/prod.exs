import Config

config :ssh_client, SSHClientWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: System.get_env("SECRET_KEY_BASE") ||
    "sshclientprodkeybase000000000000000000000000000000000000000000000",
  live_view: [signing_salt: "sshclientlv"],
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

config :logger, level: :warning
