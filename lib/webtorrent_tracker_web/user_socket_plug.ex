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
    WebSockAdapter.UpgradeError ->
      if websocket_upgrade?(conn) do
        conn
        |> send_resp(400, "invalid websocket upgrade")
        |> halt()
      else
        conn
      end
  end

  def call(conn, _opts), do: conn

  defp websocket_upgrade?(conn) do
    upgrade? =
      conn
      |> get_req_header("upgrade")
      |> Enum.any?(&(String.downcase(&1) == "websocket"))

    connection_upgrade? =
      conn
      |> get_req_header("connection")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.any?(&(String.trim(&1) |> String.downcase() == "upgrade"))

    upgrade? or connection_upgrade?
  end
end
