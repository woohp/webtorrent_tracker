defmodule WebtorrentTrackerWeb.Presence do
  use Phoenix.Presence,
    otp_app: :webtorrent_tracker,
    pubsub_server: WebtorrentTracker.PubSub
end
