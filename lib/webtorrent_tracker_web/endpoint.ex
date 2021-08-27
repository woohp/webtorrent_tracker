defmodule WebtorrentTrackerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :webtorrent_tracker

  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.MethodOverride
  plug Plug.Head
  plug WebtorrentTrackerWeb.Router
end
