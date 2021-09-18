defmodule WebtorrentTrackerWeb.UserSocketTest do
  use WebtorrentTrackerWeb.SocketCase
  alias WebtorrentTrackerWeb.UserSocket

  defp make_id(), do: List.to_string(for <<codepoint <- :rand.bytes(20)>>, do: codepoint)

  defp make_offer() do
    %{
      "offer" => %{
        "type" => "offer",
        "sdp" => "v=0\r\no=mozilla...THIS_IS_SDPARTA-91.0.1 #{:rand.uniform(10_000_000_000_000_000_000)}"
      },
      "offer_id" => make_id()
    }
  end

  defp create_state() do
    {:cowboy_websocket, nil, state} = UserSocket.init(nil, [])
    state
  end

  defp send_message(message, state) do
    case UserSocket.websocket_handle({:text, json_encode!(message)}, state) do
      {:reply, {:text, body}, state} -> {:reply, json_decode!(body), state}
      other -> other
    end
  end

  defp new_peer(peer_idx, info_hash, opts \\ %{}) do
    peer_id = "peer-#{peer_idx}______________"
    peer_offers = for _ <- 0..2, do: make_offer()
    state = create_state()

    msg = %{
      action: "announce",
      info_hash: info_hash,
      peer_id: peer_id,
      numwant: 5,
      downloaded: 0,
      uploaded: 0,
      offers: peer_offers
    }

    msg = Map.merge(msg, opts)
    {:reply, reply, state} = send_message(msg, state)
    {:ok, {peer_id, reply, state}}
  end

  defp scrape(info_hash \\ nil) do
    state = create_state()
    msg = %{"action" => "scrape"}
    msg = if is_nil(info_hash), do: msg, else: Map.put(msg, :info_hash, info_hash)
    {:reply, %{"action" => "scrape", "files" => files}, _state} = send_message(msg, state)
    files
  end

  test "two users join server" do
    info_hash = make_id()

    peer1_id = "peer-1______________"
    state1 = create_state()

    {:reply, reply, state1} =
      send_message(
        %{
          action: "announce",
          info_hash: info_hash,
          peer_id: peer1_id,
          numwant: 5,
          downloaded: 0,
          uploaded: 0,
          offers: for(_ <- 0..2, do: make_offer())
        },
        state1
      )

    assert %{
             "action" => "announce",
             "info_hash" => ^info_hash,
             "interval" => 120,
             "complete" => 0,
             "incomplete" => 1
           } = reply

    assert_receive_nothing()

    # a new peer shows up!
    peer2_id = "peer-2______________"
    peer2_offers = for _ <- 0..1, do: make_offer()
    state2 = create_state()

    {:reply, reply, _state2} =
      send_message(
        %{
          action: "announce",
          info_hash: info_hash,
          peer_id: peer2_id,
          numwant: 5,
          downloaded: 0,
          uploaded: 0,
          offers: peer2_offers
        },
        state2
      )

    assert %{
             "action" => "announce",
             "info_hash" => ^info_hash,
             "interval" => 120,
             "complete" => 0,
             # 2 users now!
             "incomplete" => 2
           } = reply

    assert Registry.count_match(WebtorrentTracker.PubSub, info_hash, :_) == 2

    assert %{
             "action" => "announce",
             "info_hash" => ^info_hash,
             "peer_id" => ^peer2_id,
             "offer" => %{
               "sdp" => <<peer2_offer_sdp::binary>>,
               "type" => "offer"
             },
             "offer_id" => <<peer2_offer_id::binary>>
           } = receive_json()

    assert_receive_nothing()

    assert peer2_offer_id in Enum.map(peer2_offers, fn offer -> offer["offer_id"] end)

    # at this point, peer1 have received the offer from peer2, and responds with an answer
    {:ok, _state1} =
      send_message(
        %{
          "action" => "announce",
          "info_hash" => info_hash,
          "peer_id" => peer1_id,
          "to_peer_id" => peer2_id,
          "offer_id" => peer2_offer_id,
          "answer" => %{
            "type" => "answer",
            "sdp" => peer2_offer_sdp
          }
        },
        state1
      )

    # and peer2 should get the answer from peer1
    assert %{
             "action" => "announce",
             "info_hash" => ^info_hash,
             "peer_id" => ^peer1_id,
             "offer_id" => ^peer2_offer_id,
             "answer" => %{
               "type" => "answer",
               "sdp" => ^peer2_offer_sdp
             }
           } = receive_json()

    # end of exchange
    assert_receive_nothing()

    # try scraping
    state3 = create_state()
    {:reply, reply, _state3} = send_message(%{"action" => "scrape"}, state3)

    assert %{
             "action" => "scrape",
             "files" => %{
               ^info_hash => %{
                 "complete" => 0,
                 "incomplete" => 2,
                 "downloaded" => 0
               }
             }
           } = reply

    # if we scrape a non-existant info_hash, we should get all zeros
    info_hash_2 = make_id()
    {:reply, reply, _state3} = send_message(%{"action" => "scrape", "info_hash" => info_hash_2}, state3)

    assert %{
             "action" => "scrape",
             "files" => %{
               ^info_hash_2 => %{
                 "complete" => 0,
                 "incomplete" => 0,
                 "downloaded" => 0
               }
             }
           } = reply

    # finally, info_hash can be a list of hashes
    info_hash_3 = make_id()

    {:reply, reply, _state3} =
      send_message(%{"action" => "scrape", "info_hash" => [info_hash, info_hash_2, info_hash_3]}, state3)

    assert %{
             "action" => "scrape",
             "files" => %{
               ^info_hash => %{
                 "complete" => 0,
                 "incomplete" => 2,
                 "downloaded" => 0
               },
               ^info_hash_2 => %{
                 "complete" => 0,
                 "incomplete" => 0,
                 "downloaded" => 0
               },
               ^info_hash_3 => %{
                 "complete" => 0,
                 "incomplete" => 0,
                 "downloaded" => 0
               }
             }
           } = reply
  end

  test "completed peers" do
    info_hash = make_id()
    {:ok, {_peer1_id, reply1, _state1}} = new_peer(1, info_hash, %{"event" => "completed"})
    {:ok, {_peer2_id, reply2, _state2}} = new_peer(2, info_hash, %{"event" => "started"})
    {:ok, {_peer3_id, reply3, _state3}} = new_peer(3, info_hash)
    {:ok, {_peer4_id, reply4, _state4}} = new_peer(4, info_hash, %{"event" => "completed"})

    assert %{"complete" => 1, "incomplete" => 0} = reply1
    assert %{"complete" => 1, "incomplete" => 1} = reply2
    assert %{"complete" => 1, "incomplete" => 2} = reply3
    assert %{"complete" => 2, "incomplete" => 2} = reply4

    # a scrape should reveal the current state
    assert %{
             ^info_hash => %{
               "complete" => 2,
               "incomplete" => 2,
               "downloaded" => 2
             }
           } = scrape()
  end

  test "client starts and then completes" do
    info_hash = make_id()
    {:ok, {_peer1_id, _reply1, _state1}} = new_peer(1, info_hash, %{"event" => "completed"})
    {:ok, {peer2_id, _reply2, state2}} = new_peer(2, info_hash, %{"event" => "started"})
    {:ok, {_peer3_id, _reply3, _state3}} = new_peer(3, info_hash)

    # 1 complete, 2 incomplete
    assert %{^info_hash => %{"complete" => 1, "incomplete" => 2}} = scrape()

    # peer2 announces complete
    send_message(%{action: "announce", event: "completed", info_hash: info_hash, peer_id: peer2_id}, state2)
    assert %{^info_hash => %{"complete" => 2, "incomplete" => 1}} = scrape()
  end

  test "client stopping" do
    info_hash = make_id()
    {:ok, {peer1_id, reply1, state1}} = new_peer(1, info_hash, %{"event" => "completed"})
    assert %{"complete" => 1, "incomplete" => 0} = reply1

    # if a peer stops, it should unsubscribe from the channel
    send_message(
      %{"action" => "announce", "info_hash" => info_hash, "peer_id" => peer1_id, "event" => "stopped"},
      state1
    )

    assert map_size(scrape()) == 0
  end
end
