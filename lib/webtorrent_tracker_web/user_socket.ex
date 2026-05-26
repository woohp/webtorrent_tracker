defmodule WebtorrentTrackerWeb.UserSocket do
  @announce_interval 120

  @behaviour WebSock

  @impl WebSock
  def init([]) do
    pubsub_server =
      Application.get_env(:webtorrent_tracker, WebtorrentTrackerWeb.UserSocket)
      |> Keyword.fetch!(:pubsub_server)

    {:ok, %{pubsub_server: pubsub_server}}
  end

  @impl WebSock
  def handle_in({body, [opcode: opcode]}, state) when opcode in [:text, :binary] do
    with {:ok, %{} = body} <- Phoenix.json_library().decode(body) do
      case handle(body, state) do
        {:noreply, state} ->
          {:ok, state}

        {:reply, reply, state} ->
          {:push, {:text, Phoenix.json_library().encode!(reply)}, state}

        {:stop, state} ->
          {:stop, :normal, state}
      end
    else
      _ -> {:stop, :normal, state}
    end
  end

  @impl WebSock
  def handle_info(info, state) when is_binary(info) do
    {:push, {:text, info}, state}
  end

  def handle_info(:disconnect, state) do
    {:stop, :normal, state}
  end

  defp handle(%{"action" => "announce"} = message, state) do
    with %{"info_hash" => info_hash, "peer_id" => peer_id} <- message,
         true <- twenty_char_id?(info_hash),
         true <- twenty_char_id?(peer_id) do
      case message["event"] do
        nil ->
          if is_nil(message["answer"]) do
            process_announce(message, state)
          else
            process_answer(message, state)
          end

        "started" ->
          process_announce(message, state, complete_status(message, state))

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
    with {:ok, files} <- scrape_files(message, pubsub_server) do
      {:reply, %{"action" => "scrape", "files" => files}, state}
    else
      :error -> {:stop, state}
    end
  end

  defp handle(_message, state) do
    {:stop, state}
  end

  defp process_announce(message, state, complete \\ nil) do
    pubsub_server = state.pubsub_server
    info_hash = message["info_hash"]
    peer_id = message["peer_id"]
    complete = if is_nil(complete), do: complete_status(message, state), else: complete

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

    state = put_complete_status(state, info_hash, complete)

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

  defp scrape_files(%{"info_hash" => info_hash}, pubsub_server) when is_binary(info_hash) do
    if twenty_char_id?(info_hash) do
      {:ok, scrape_info_hashes([info_hash], pubsub_server)}
    else
      :error
    end
  end

  defp scrape_files(%{"info_hash" => info_hashes}, pubsub_server) when is_list(info_hashes) do
    if Enum.all?(info_hashes, &twenty_char_id?/1) do
      {:ok, scrape_info_hashes(info_hashes, pubsub_server)}
    else
      :error
    end
  end

  defp scrape_files(%{"info_hash" => _info_hash}, _pubsub_server), do: :error

  defp scrape_files(_message, pubsub_server) do
    # if we aren't given the info_hash(es), then just query everything and aggregate manually
    files =
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

    {:ok, files}
  end

  defp scrape_info_hashes(info_hashes, pubsub_server) do
    for info_hash <- info_hashes, into: %{} do
      complete_count = Registry.count_match(pubsub_server, info_hash, %{complete: 1})
      num_peers = Registry.count_match(pubsub_server, info_hash, :_)
      incomplete_count = num_peers - complete_count

      {info_hash, %{complete: complete_count, incomplete: incomplete_count, downloaded: complete_count}}
    end
  end

  defp send_offers_to_peers(pubsub_server, from, %{"offers" => [_ | _]} = message) do
    topic = message["info_hash"]
    dispatcher = WebtorrentTrackerWeb.UserSocket
    {:ok, {adapter, name}} = Registry.meta(pubsub_server, :pubsub)

    with :ok <- adapter.broadcast(name, topic, message, dispatcher) do
      Registry.dispatch(pubsub_server, topic, {dispatcher, :dispatch, [from, message]})
    end

    :ok
  end

  defp send_offers_to_peers(_pubsub_server, _from, _message), do: :ok

  defp process_answer(
         %{"to_peer_id" => to_peer_id, "offer_id" => offer_id, "answer" => answer} = message,
         %{peer_id: peer_id} = state
       )
       when is_binary(offer_id) do
    {_to_peer_id, reply} = Map.pop(message, "to_peer_id")
    reply = %{reply | "peer_id" => peer_id}

    if twenty_char_id?(to_peer_id) and valid_answer?(answer) and
         Registry.count_match(state.pubsub_server, to_peer_id, :_) > 0 do
      Phoenix.PubSub.broadcast(
        state.pubsub_server,
        to_peer_id,
        Phoenix.json_library().encode!(reply)
      )

      {:noreply, state}
    else
      {:stop, state}
    end
  end

  defp process_answer(_message, state), do: {:stop, state}

  defp process_stop(message, state) do
    Phoenix.PubSub.unsubscribe(state.pubsub_server, message["info_hash"])

    {:noreply, delete_complete_status(state, message["info_hash"])}
  end

  @impl WebSock
  def terminate(_reason, _state) do
    :ok
  end

  def dispatch(
        entries,
        from,
        %{
          "info_hash" => info_hash,
          "peer_id" => peer_id,
          "offers" => offers
        } = message
      )
      when from != :none and is_list(offers) do
    pids =
      for {pid, %{peer_id: peer_id}} <- entries, peer_id != from do
        pid
      end

    offers = Enum.filter(offers, &valid_offer?/1)
    numwant = offer_count(message, offers)

    for {offer, pid} <- Enum.zip(Enum.take(offers, numwant), Enum.take_random(pids, numwant)) do
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

  defp valid_offer?(%{"offer_id" => offer_id, "offer" => %{"type" => "offer", "sdp" => sdp}})
       when is_binary(offer_id) and is_binary(sdp),
       do: true

  defp valid_offer?(_offer), do: false

  defp valid_answer?(%{"type" => "answer", "sdp" => sdp}) when is_binary(sdp), do: true
  defp valid_answer?(_answer), do: false

  defp twenty_char_id?(value) when is_binary(value), do: length(String.to_charlist(value)) == 20
  defp twenty_char_id?(_value), do: false

  defp complete_status(%{"event" => "completed"}, _state), do: 1

  defp complete_status(%{"info_hash" => info_hash}, state) do
    state
    |> Map.get(:complete, %{})
    |> Map.get(info_hash, 0)
  end

  defp put_complete_status(state, info_hash, complete) do
    completes =
      state
      |> Map.get(:complete, %{})
      |> Map.put(info_hash, complete)

    Map.put(state, :complete, completes)
  end

  defp delete_complete_status(state, info_hash) do
    completes =
      state
      |> Map.get(:complete, %{})
      |> Map.delete(info_hash)

    Map.put(state, :complete, completes)
  end

  defp offer_count(%{"numwant" => numwant}, offers) when is_integer(numwant) and numwant >= 0 do
    min(numwant, length(offers))
  end

  defp offer_count(%{"numwant" => _numwant}, _offers), do: 0

  defp offer_count(_message, offers), do: length(offers)
end
