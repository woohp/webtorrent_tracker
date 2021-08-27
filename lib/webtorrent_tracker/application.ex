defmodule WebtorrentTracker.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      WebtorrentTrackerWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: WebtorrentTracker.PubSub},
      # WebtorrentTrackerWeb.Presence,
      # Start the Endpoint (http/https)
      WebtorrentTrackerWeb.Endpoint,
      # Start a worker by calling: WebtorrentTracker.Worker.start_link(arg)
      # {WebtorrentTracker.Worker, arg}
      WebtorrentTrackerWeb.SwarmState
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: WebtorrentTracker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    WebtorrentTrackerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
