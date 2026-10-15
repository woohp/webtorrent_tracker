defmodule WebtorrentTrackerWeb.UserSocket do
  @behaviour WebSock

  @announce_interval 120
  @swarms WebtorrentTracker.Swarms
  @peers WebtorrentTracker.Peers

  @impl WebSock
  def init([]) do
    {:ok, %{peer_id: nil, complete: %{}}}
  end

  @impl WebSock
  def handle_in({body, [opcode: opcode]}, state) when opcode in [:text, :binary] do
    case JSON.decode(body) do
      {:ok, %{} = message} -> handle(message, state)
      _ -> {:stop, :normal, state}
    end
  end

  # binaries are messages already encoded for this peer by another socket
  @impl WebSock
  def handle_info(message, state) when is_binary(message) do
    {:push, {:text, message}, state}
  end

  def handle_info(:disconnect, state) do
    {:stop, :normal, state}
  end

  defp handle(%{"action" => "announce", "info_hash" => info_hash, "peer_id" => peer_id} = message, state) do
    if twenty_char_id?(info_hash) and twenty_char_id?(peer_id) do
      case {message["event"], message["answer"]} do
        {nil, nil} -> process_announce(message, state)
        {nil, _answer} -> process_answer(message, state)
        {event, _answer} when event in ["started", "completed"] -> process_announce(message, state)
        {"stopped", _answer} -> process_stop(message, state)
        _ -> {:stop, :normal, state}
      end
    else
      {:stop, :normal, state}
    end
  end

  defp handle(%{"action" => "scrape"} = message, state) do
    case scrape_info_hashes(message) do
      {:ok, info_hashes} ->
        files =
          Map.new(info_hashes, fn info_hash ->
            stats = swarm_stats(info_hash)
            {info_hash, Map.put(stats, :downloaded, stats.complete)}
          end)

        reply(%{action: "scrape", files: files}, state)

      :error ->
        {:stop, :normal, state}
    end
  end

  defp handle(_message, state) do
    {:stop, :normal, state}
  end

  defp process_announce(%{"info_hash" => info_hash, "peer_id" => peer_id} = message, state) do
    state = register_peer(state, peer_id)
    complete = complete_status(message, state)

    Registry.unregister_match(@swarms, info_hash, %{peer_id: peer_id})
    {:ok, _owner} = Registry.register(@swarms, info_hash, %{peer_id: peer_id, complete: complete})
    send_offers(message)

    # these counts can include an old socket that was told to disconnect but hasn't exited yet
    reply = Map.merge(%{action: "announce", interval: @announce_interval, info_hash: info_hash}, swarm_stats(info_hash))
    reply(reply, put_in(state.complete[info_hash], complete))
  end

  defp process_answer(
         %{"to_peer_id" => to_peer_id, "offer_id" => offer_id, "answer" => answer} = message,
         %{peer_id: peer_id} = state
       )
       when is_binary(peer_id) and is_binary(offer_id) do
    if twenty_char_id?(to_peer_id) and valid_answer?(answer) do
      # the answer may race with the offering peer leaving, so an unknown peer is not an error
      answer_message =
        message
        |> Map.delete("to_peer_id")
        |> Map.put("peer_id", peer_id)
        |> JSON.encode!()

      for {pid, _value} <- Registry.lookup(@peers, to_peer_id) do
        send(pid, answer_message)
      end

      {:ok, state}
    else
      {:stop, :normal, state}
    end
  end

  defp process_answer(_message, state), do: {:stop, :normal, state}

  defp process_stop(%{"info_hash" => info_hash}, state) do
    Registry.unregister(@swarms, info_hash)
    {:ok, %{state | complete: Map.delete(state.complete, info_hash)}}
  end

  defp scrape_info_hashes(%{"info_hash" => info_hashes}) do
    info_hashes = List.wrap(info_hashes)

    if Enum.all?(info_hashes, &twenty_char_id?/1) do
      {:ok, info_hashes}
    else
      :error
    end
  end

  # without info hashes, scrape every swarm
  defp scrape_info_hashes(_message) do
    info_hashes =
      @swarms
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.uniq()

    {:ok, info_hashes}
  end

  defp reply(reply, state) do
    {:push, {:text, JSON.encode!(reply)}, state}
  end

  # a peer that reconnects on a new socket replaces its old one
  defp register_peer(%{peer_id: nil} = state, peer_id) do
    for {pid, _value} <- Registry.lookup(@peers, peer_id) do
      send(pid, :disconnect)
    end

    {:ok, _owner} = Registry.register(@peers, peer_id, nil)
    %{state | peer_id: peer_id}
  end

  defp register_peer(state, _peer_id), do: state

  defp complete_status(%{"event" => "completed"}, _state), do: 1
  defp complete_status(%{"info_hash" => info_hash}, state), do: Map.get(state.complete, info_hash, 0)

  defp send_offers(%{"info_hash" => info_hash, "peer_id" => peer_id, "offers" => [_ | _] = offers} = message) do
    offers =
      case Map.get(message, "numwant", length(offers)) do
        numwant when is_integer(numwant) and numwant >= 0 ->
          offers
          |> Enum.filter(&valid_offer?/1)
          |> Enum.take(numwant)

        _numwant ->
          []
      end

    pids =
      for {pid, %{peer_id: other_peer_id}} <- Registry.lookup(@swarms, info_hash), other_peer_id != peer_id do
        pid
      end

    for {offer, pid} <- Enum.zip(offers, Enum.take_random(pids, length(offers))) do
      send(
        pid,
        JSON.encode!(%{
          action: "announce",
          info_hash: info_hash,
          peer_id: peer_id,
          offer_id: offer["offer_id"],
          offer: offer["offer"]
        })
      )
    end
  end

  defp send_offers(_message), do: :ok

  defp swarm_stats(info_hash) do
    complete = Registry.count_match(@swarms, info_hash, %{complete: 1})
    %{complete: complete, incomplete: Registry.count_match(@swarms, info_hash, :_) - complete}
  end

  defp valid_offer?(%{"offer_id" => offer_id, "offer" => %{"type" => "offer", "sdp" => sdp}})
       when is_binary(offer_id) and is_binary(sdp),
       do: true

  defp valid_offer?(_offer), do: false

  defp valid_answer?(%{"type" => "answer", "sdp" => sdp}) when is_binary(sdp), do: true
  defp valid_answer?(_answer), do: false

  defp twenty_char_id?(value) when is_binary(value), do: length(String.to_charlist(value)) == 20
  defp twenty_char_id?(_value), do: false
end
