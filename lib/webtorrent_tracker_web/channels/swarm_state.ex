defmodule WebtorrentTrackerWeb.SwarmState do
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end
end
