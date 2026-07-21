defmodule MafiaWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :mafia

  @session_options [
    store: :cookie,
    key: "_mafia_key",
    signing_salt: "pJ7vQ2cL",
    encryption_salt: "cN8sW4hR",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :x_headers, session: @session_options], compress: true],
    longpoll: [connect_info: [:peer_data, :x_headers, session: @session_options]]

  plug RemoteIp, headers: ["x-real-ip"]

  plug Plug.Static,
    at: "/",
    from: :mafia,
    gzip: not code_reloading?,
    only: MafiaWeb.static_paths()

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :mafia
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug MafiaWeb.Router
end
