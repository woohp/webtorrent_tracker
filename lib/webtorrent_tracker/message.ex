defmodule WebtorrentTracker.Message do
  @moduledoc """
  Defines a message dispatched over transport to channels and vice-versa.

  The message format requires the following keys:

    * `:topic` - The string topic or topic:subtopic pair namespace, for
      example "messages", "messages:123"
    * `:event`- The string event name, for example "phx_join"
    * `:payload` - The message payload
    * `:ref` - The unique string ref
    * `:join_ref` - The unique string ref when joining

  """

  @type t :: %WebtorrentTracker.Message{}
  defstruct info_hash: nil,
            peer_id: nil,
            action: nil,
            event: nil,
            numwant: nil,
            uploaded: nil,
            downloaded: nil,
            offers: nil

  @doc """
  Converts a map with string keys into a message struct.

  Raises `Phoenix.Socket.InvalidMessageError` if not valid.
  """
  def from_map!(map) when is_map(map) do
    try do
      %WebtorrentTracker.Message{
        info_hash: Map.fetch!(map, "info_hash"),
        peer_id: Map.fetch!(map, "peer_id"),
        action: Map.fetch!(map, "action"),
        event: Map.fetch!(map, "event"),
        numwant: Map.fetch!(map, "numwant"),
        uploaded: Map.get(map, "uploaded"),
        downloaded: Map.get(map, "downloaded"),
        offers: Map.get(map, "offers")
      }
    rescue
      err in [KeyError] ->
        raise Phoenix.Socket.InvalidMessageError, "missing key #{inspect(err.key)}"
    end
  end
end
