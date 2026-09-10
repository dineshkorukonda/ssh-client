defmodule SSHClientWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :ssh_client

  # The session will be stored in the cookie and signed.
  @session_options [
    store: :cookie,
    key: "_ssh_client_key",
    signing_salt: "sshclient1",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  socket "/socket", SSHClientWeb.UserSocket,
    websocket: true,
    longpoll: false

  # Serve static files from priv/static
  plug Plug.Static,
    at: "/",
    from: :ssh_client,
    gzip: false,
    only: SSHClientWeb.static_paths()

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug SSHClientWeb.Router
end
