defmodule WebtorrentTrackerWeb.UserSocketPlug do
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", request_path: "/"} = conn, _opts) do
    WebSockAdapter.upgrade(conn, WebtorrentTrackerWeb.UserSocket, [], timeout: 60_000)
  rescue
    WebSockAdapter.UpgradeError -> send_resp(conn, 400, "invalid websocket upgrade")
  end

  def call(conn, _opts), do: send_resp(conn, 404, "not found")
end
