defmodule WebtorrentTracker.Serializer do
  @moduledoc false
  @behaviour Phoenix.Socket.Serializer

  alias Phoenix.Socket.{Broadcast, Message, Reply}

  @impl true
  def fastlane!(%Broadcast{} = msg) do
    {:socket_push, :text, encode_map!(msg.payload)}
  end

  @impl true
  def encode!(%Reply{} = reply) do
    {:socket_push, :text, encode_map!(reply.payload)}
  end

  def encode!(%Message{} = map) do
    {:socket_push, :text, encode_map!(map.payload)}
  end

  defp encode_map!(map) do
    Phoenix.json_library().encode_to_iodata!(map)
  end

  @impl true
  def decode!(message, _opts) do
    message
    |> Phoenix.json_library().decode!()
    |> message_from_map!()
  end

  defp message_from_map!(
         %{"info_hash" => info_hash, "peer_id" => peer_id, "action" => action} = map
       ) do
    event =
      if action == "announce" and (map["event"] == "started" or !is_nil(map["offers"])),
        do: "phx_join",
        else: "announce"

    # IO.inspect(map, label: "event")

    %Message{
      topic: info_hash,
      event: event,
      ref: peer_id,
      payload: map
    }
  end

  defp message_from_map!(stuff) do
    IO.inspect(stuff, label: "stuff")
    stuff
  end
end
