defmodule WebtorrentTrackerWeb.UserSocket do
  if Code.ensure_loaded?(:cowboy_websocket) and
       function_exported?(:cowboy_websocket, :behaviour_info, 1) do
    @behaviour :cowboy_websocket
  end

  def init(req, []) do
    pubsub_server =
      Application.get_env(:webtorrent_tracker, WebtorrentTrackerWeb.UserSocket)
      |> Keyword.fetch!(:pubsub_server)

    {:cowboy_websocket, req, %{info_hashes: MapSet.new(), pubsub_server: pubsub_server}}
  end

  def websocket_handle({opcode, body}, state) when opcode in [:text, :binary] do
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

      unrecognized_out ->
        raise "unexpected output: #{inspect(unrecognized_out)}"
    end
  end

  def websocket_info(info, state) when is_binary(info) do
    {:reply, {:text, info}, state}
  end

  def websocket_info(:disconnect, state) do
    {:stop, state}
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
    pubsub_server = state.pubsub_server
    info_hash = message["info_hash"]
    peer_id = message["peer_id"]

    state =
      if !Map.has_key?(state, :peer_id) do
        # if we have an old peer, then it means the peer has changed socket
        # send a message to that connection to disconnect
        if Registry.count_match(pubsub_server, peer_id, :_) == 1 do
          Phoenix.PubSub.broadcast(pubsub_server, peer_id, :disconnect)
        end

        Phoenix.PubSub.subscribe(pubsub_server, peer_id)
        Phoenix.PubSub.subscribe(pubsub_server, info_hash, metadata: %{complete: complete})

        Map.put(state, :peer_id, peer_id)
      else
        state
      end

    state = %{state | info_hashes: MapSet.put(state.info_hashes, info_hash)}

    send_offers_to_peers(pubsub_server, message)

    # these metrics can be wrong if we have disconnected an old peer, but it hasn't processed the terminate cmd yet
    complete_count = Registry.count_match(pubsub_server, info_hash, %{complete: true})
    num_peers = Registry.count_match(pubsub_server, info_hash, :_)
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

  defp send_offers_to_peers(pubsub_server, message) do
    if message["offers"] do
      Phoenix.PubSub.broadcast_from!(
        pubsub_server,
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
      state.pubsub_server,
      to_peer_id,
      Phoenix.json_library().encode!(reply)
    )

    {:noreply, state}
  end

  defp process_stop(message, state) do
    info_hash = message["info_hash"]
    Phoenix.PubSub.unsubscribe(state.pubsub_server, info_hash)
    state = %{state | info_hashes: MapSet.delete(state.info_hashes, info_hash)}

    {:noreply, state}
  end

  def terminate(_reason, _req, _state) do
    # IO.puts("terminate!")
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
end
