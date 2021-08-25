defmodule WebtorrentTrackerWeb.RoomChannel do
  use WebtorrentTrackerWeb, :channel

  @impl true
  def join(<<info_hash::binary>>, payload, socket) do
    IO.puts("join")
    dbg(payload)

    WebtorrentTrackerWeb.Endpoint.subscribe(payload["peer_id"])

    reply = %{
      action: "announce",
      interval: 12,
      info_hash: payload["info_hash"],
      complete: 0,
      incomplete: 1
    }

    send(self(), {:after_join, payload})

    socket = %{socket | id: payload["peer_id"]}

    {:ok, reply, socket}
  end

  @impl true
  def handle_info({:after_join, %{} = payload}, socket) do
    send_offers_to_peers(payload, socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{payload: %{"answer" => _answer} = payload}, socket) do
    push(socket, "announce", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("announce", payload, socket) do
    process(payload, socket)
    {:noreply, socket}
  end

  @impl true
  def handle_in("scrape", payload, socket) do
    process(payload, socket)
    {:noreply, socket}
  end

  defp process(%{"action" => "announce"} = payload, socket) do
    case payload["event"] do
      nil ->
        answer = payload["answer"]

        if is_nil(answer) do
          process_announce(payload, socket)
        else
          process_answer(payload, socket)
        end

      "started" ->
        process_announce(payload, socket)

      "stopped" ->
        process_stop(payload, socket)

      "completed" ->
        process_announce(payload, socket, true)
    end
  end

  defp process(%{"action" => "scape"} = _payload, socket) do
    {:noreply, socket}
  end

  defp process_announce(payload, socket, completed \\ false) do
    IO.inspect("process_announce")

    push(socket, "announce", %{
      action: "announce",
      interval: 120,
      info_hash: payload["info_hash"],
      complete: 0,
      incomplete: 1
    })

    send_offers_to_peers(payload, socket)

    {:noreply, socket}
  end

  defp process_answer(payload, socket) do
    to_peer_id = payload["to_peer_id"]
    # dbg("answering to #{to_peer_id}")
    # dbg(socket.id)
    payload = %{payload | "peer_id" => socket.id}
    payload = Map.drop(payload, ["to_peer_id"])

    WebtorrentTrackerWeb.Endpoint.broadcast(to_peer_id, "announce", payload)

    {:noreply, socket}
  end

  defp process_stop(payload, socket) do
    {:noreply, socket}
  end

  defp process_completed(payload, socket) do
    {:noreply, socket}
  end

  defp send_offers_to_peers(payload, socket) do
    # dbg(payload)
    offer = hd(payload["offers"])

    out =
      broadcast_from!(socket, "announce", %{
        action: "announce",
        info_hash: payload["info_hash"],
        peer_id: payload["peer_id"],
        offer_id: offer["offer_id"],
        offer: offer["offer"]
      })

    out
  end
end
