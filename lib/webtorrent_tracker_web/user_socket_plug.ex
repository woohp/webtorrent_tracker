defmodule WebtorrentTrackerWeb.UserSocketPlug do
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", request_path: "/"} = conn, _opts) do
    # the idle timeout must outlast UserSocket's 120s announce interval, or quiet peers drop between announces
    WebSockAdapter.upgrade(conn, WebtorrentTrackerWeb.UserSocket, [], timeout: :timer.minutes(4))
  rescue
    WebSockAdapter.UpgradeError -> send_resp(conn, 400, "invalid websocket upgrade")
  end

  def call(conn, _opts), do: send_resp(conn, 404, "not found")
end
