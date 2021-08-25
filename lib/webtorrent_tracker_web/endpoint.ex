defmodule WebtorrentTrackerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :webtorrent_tracker

  socket "/", WebtorrentTrackerWeb.UserSocket,
    websocket: [path: "/", serializer: [{WebtorrentTracker.Serializer, "~> 1.0.0"}]],
    longpoll: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug WebtorrentTrackerWeb.Router
end
