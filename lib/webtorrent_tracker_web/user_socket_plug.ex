defmodule WebtorrentTrackerWeb.UserSocketPlug do
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", request_path: "/"} = conn, _opts) do
    conn
    |> WebSockAdapter.upgrade(WebtorrentTrackerWeb.UserSocket, [], timeout: 60_000)
    |> halt()
  rescue
    WebSockAdapter.UpgradeError -> conn
  end

  def call(conn, _opts), do: conn
end
