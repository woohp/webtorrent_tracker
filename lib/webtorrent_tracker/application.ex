defmodule WebtorrentTracker.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: WebtorrentTracker.Swarms},
      {Registry, keys: :duplicate, name: WebtorrentTracker.Peers}
    ]

    children =
      if Application.get_env(:webtorrent_tracker, :server, true) do
        port = Application.fetch_env!(:webtorrent_tracker, :port)
        children ++ [{Bandit, plug: WebtorrentTrackerWeb.UserSocketPlug, port: port}]
      else
        children
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: WebtorrentTracker.Supervisor)
  end
end
