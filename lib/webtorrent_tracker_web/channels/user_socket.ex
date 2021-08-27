defmodule WebtorrentTrackerWeb.UserSocket do
  if Code.ensure_loaded?(:cowboy_websocket) and
       function_exported?(:cowboy_websocket, :behaviour_info, 1) do
    @behaviour :cowboy_websocket
  end

  def init(req, []) do
    {:cowboy_websocket, req, %{info_hashes: MapSet.new()}}
  end

  def websocket_handle({:text, body}, state) do
    body = Phoenix.json_library().decode!(body)

    out =
      try do
        handle(body, state)
      rescue
        FunctionClauseError -> {:stop, state}
      end

    case out do
      {:noreply, state} ->
        {:ok, state}

      {:reply, reply, state} ->
        {:reply, {:text, Phoenix.json_library().encode!(reply)}, state}

      {:stop, _state} ->
        out

      what ->
        IO.inspect(what, label: "what")
    end
  end

  def websocket_info(info, state) do
    {:reply, {:text, info}, state}
  end

  defp handle(%{"action" => "announce", "info_hash" => <<_::binary>>} = message, state) do
    case message["event"] do
      nil ->
        if is_nil(message["answer"]) do
          process_announce(message, state)
        else
          process_answer(message, state)
        end

      "started" ->
        process_announce(message, state)

      "stopped" ->
        process_stop(message, state)

      "completed" ->
        process_announce(message, state, true)

      _ ->
        {:stop, state}
    end
  end

  defp handle(%{"action" => "scrape"} = _message, state) do
    {:noreply, state}
  end

  defp process_announce(message, state, complete \\ false) do
    info_hash = message["info_hash"]
    peer_id = message["peer_id"]

    state =
      if !Map.has_key?(state, :peer_id) do
        Phoenix.PubSub.subscribe(WebtorrentTracker.PubSub, peer_id)
        Phoenix.PubSub.subscribe(WebtorrentTracker.PubSub, info_hash)
        Map.put(state, :peer_id, peer_id)
      end

    state = %{state | info_hashes: MapSet.put(state.info_hashes, info_hash)}

    send_offers_to_peers(message)

    complete_count =
      Agent.get_and_update(WebtorrentTrackerWeb.SwarmState, fn state ->
        completed_peers = Map.get_lazy(state, info_hash, &MapSet.new/0)

        completed_peers =
          if complete, do: MapSet.put(completed_peers, peer_id), else: completed_peers

        state = Map.put(state, info_hash, completed_peers)
        {MapSet.size(completed_peers), state}
      end)

    num_peers = swarm_size(info_hash)
    incomplete_count = num_peers - complete_count

    reply = %{
      action: "announce",
      interval: 120,
      info_hash: info_hash,
      complete: complete_count,
      incomplete: incomplete_count
    }

    {:reply, reply, state}
  end

  defp send_offers_to_peers(message) do
    if message["offers"] do
      Phoenix.PubSub.broadcast_from!(
        WebtorrentTracker.PubSub,
        self(),
        message["info_hash"],
        message,
        WebtorrentTrackerWeb.UserSocket
      )
    end
  end

  defp process_answer(message, state) do
    {to_peer_id, reply} = Map.pop(message, "to_peer_id")
    reply = %{reply | "peer_id" => state.peer_id}

    Phoenix.PubSub.broadcast(
      WebtorrentTracker.PubSub,
      to_peer_id,
      Phoenix.json_library().encode!(reply)
    )

    {:noreply, state}
  end

  defp process_stop(message, state) do
    info_hash = message["info_hash"]
    remove_from_swarm(state.peer_id, info_hash)
    state = %{state | info_hashes: MapSet.delete(state.info_hashes, info_hash)}

    {:noreply, state}
  end

  def terminate(_reason, _req, state) do
    disconnect_peer(state)
    :ok
  end

  defp disconnect_peer(state) do
    Phoenix.PubSub.unsubscribe(WebtorrentTracker.PubSub, state.peer_id)

    for info_hash <- state.info_hashes do
      remove_from_swarm(state.peer_id, info_hash)
    end

    state = %{state | info_hashes: MapSet.new()}

    state
  end

  defp remove_from_swarm(peer_id, info_hash) do
    Phoenix.PubSub.unsubscribe(WebtorrentTracker.PubSub, info_hash)

    Agent.update(WebtorrentTrackerWeb.SwarmState, fn state ->
      completed_peers = state[info_hash]

      completed_peers =
        if MapSet.member?(completed_peers, peer_id) do
          MapSet.delete(completed_peers, peer_id)
        else
          completed_peers
        end

      if MapSet.size(completed_peers) do
        Map.delete(state, info_hash)
      else
        %{state | info_hash => completed_peers}
      end
    end)

    :ok
  end

  def dispatch(entries, from, %{
        "info_hash" => info_hash,
        "peer_id" => peer_id,
        "offers" => offers
      })
      when from != :none do
    pids =
      for {pid, _} <- entries, pid != from do
        pid
      end

    for {offer, pid} <- Enum.zip(offers, Enum.take_random(pids, length(offers))) do
      send(
        pid,
        Phoenix.json_library().encode!(%{
          action: "announce",
          info_hash: info_hash,
          peer_id: peer_id,
          offer_id: offer["offer_id"],
          offer: offer["offer"]
        })
      )
    end

    :ok
  end

  defp swarm_size(info_hash) do
    Registry.count_match(WebtorrentTracker.PubSub, info_hash, :_)
  end
end
