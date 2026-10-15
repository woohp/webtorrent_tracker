defmodule WebtorrentTracker.MixProject do
  use Mix.Project

  def project do
    [
      app: :webtorrent_tracker,
      version: "0.1.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {WebtorrentTracker.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.11"},
      {:websock_adapter, "~> 0.5.9"}
    ]
  end
end
