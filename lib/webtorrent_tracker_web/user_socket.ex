defmodule WebtorrentTrackerWeb.UserSocket do
  @announce_interval 120

  if Code.ensure_loaded?(:cowboy_websocket) and
       function_exported?(:cowboy_websocket, :behaviour_info, 1) do
    @behaviour :cowboy_websocket
  end

  def init(req, []) do
    pubsub_server =
      Application.get_env(:webtorrent_tracker, WebtorrentTrackerWeb.UserSocket)
      |> Keyword.fetch!(:pubsub_server)

    {:cowboy_websocket, req, %{pubsub_server: pubsub_server}}
  end

  def websocket_handle({opcode, body}, state) when opcode in [:text, :binary] do
    with {:ok, %{} = body} <- Phoenix.json_library().decode(body) do
      case out = handle(body, state) do
        {:noreply, state} ->
          {:ok, state}

        {:reply, reply, state} ->
          {:reply, {:text, Phoenix.json_library().encode!(reply)}, state}

        {:stop, _state} ->
          out

        unrecognized_output ->
          raise "unexpected output: #{inspect(unrecognized_output)}"
      end
    else
      _ -> {:stop, state}
    end
  end

  def websocket_info(info, state) when is_binary(info) do
    {:reply, {:text, info}, state}
  end

  def websocket_info(:disconnect, state) do
    {:stop, state}
  end

  defp handle(%{"action" => "announce"} = message, state) do
    with 20 <- length(String.to_charlist(message["info_hash"])),
         20 <- length(String.to_charlist(message["peer_id"])) do
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
          process_announce(message, state, 1)

        _ ->
          {:stop, state}
      end
    else
      _ -> {:stop, state}
    end
  end

  defp handle(%{"action" => "scrape"} = message, %{pubsub_server: pubsub_server} = state) do
    files =
      if info_hash = message["info_hash"] do
        info_hashes =
          if is_binary(info_hash) do
            [info_hash]
          else
            info_hash
          end

        for info_hash <- info_hashes, into: %{} do
          complete_count = Registry.count_match(pubsub_server, info_hash, %{complete: 1})
          num_peers = Registry.count_match(pubsub_server, info_hash, :_)
          incomplete_count = num_peers - complete_count

          {info_hash, %{complete: complete_count, incomplete: incomplete_count, downloaded: complete_count}}
        end
      else
        # if we aren't given the info_hash(es), then just query everything and aggregate manually
        Registry.select(pubsub_server, [{{:"$1", :_, %{complete: :"$2"}}, [], [{{:"$1", :"$2"}}]}])
        |> Enum.group_by(fn {info_hash, _} -> info_hash end, fn {_, complete} -> complete end)
        |> Enum.into(%{}, fn {info_hash, completes} ->
          complete_count = Enum.sum(completes)
          total_count = length(completes)

          {info_hash,
           %{
             complete: complete_count,
             incomplete: total_count - complete_count,
             downloaded: complete_count
           }}
        end)
      end

    {:reply, %{"action" => "scrape", "files" => files}, state}
  end

  defp handle(_message, state) do
    {:stop, state}
  end

  defp process_announce(message, state, complete \\ 0) do
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
        Map.put(state, :peer_id, peer_id)
      else
        state
      end

    Registry.unregister_match(pubsub_server, info_hash, %{peer_id: peer_id})
    Phoenix.PubSub.subscribe(pubsub_server, info_hash, metadata: %{complete: complete, peer_id: peer_id})

    send_offers_to_peers(pubsub_server, peer_id, message)

    # these metrics can be wrong if we have disconnected an old peer, but it hasn't processed the terminate cmd yet
    complete_count = Registry.count_match(pubsub_server, info_hash, %{complete: 1})
    num_peers = Registry.count_match(pubsub_server, info_hash, :_)
    incomplete_count = num_peers - complete_count

    reply = %{
      action: "announce",
      interval: @announce_interval,
      info_hash: info_hash,
      complete: complete_count,
      incomplete: incomplete_count
    }

    {:reply, reply, state}
  end

  defp send_offers_to_peers(pubsub_server, from, message) do
    if message["offers"] do
      topic = message["info_hash"]
      dispatcher = WebtorrentTrackerWeb.UserSocket
      {:ok, {adapter, name}} = Registry.meta(pubsub_server, :pubsub)

      with :ok <- adapter.broadcast(name, topic, message, dispatcher) do
        Registry.dispatch(pubsub_server, topic, {dispatcher, :dispatch, [from, message]})
      end
    end

    :ok
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
    Phoenix.PubSub.unsubscribe(state.pubsub_server, message["info_hash"])

    {:noreply, state}
  end

  def terminate(_reason, _req, _state) do
    # IO.puts("terminate!")
    :ok
  end

  def dispatch(
        entries,
        from,
        %{
          "info_hash" => info_hash,
          "peer_id" => peer_id,
          "offers" => offers
        } = _message
      )
      when from != :none do
    pids =
      for {pid, %{peer_id: peer_id}} <- entries, peer_id != from do
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
