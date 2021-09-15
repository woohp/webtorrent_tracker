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

  def create_state() do
    {:cowboy_websocket, nil, state} = UserSocket.init(nil, [])
    state
  end

  def send_message(message, state) do
    case UserSocket.websocket_handle({:text, json_encode!(message)}, state) do
      {:reply, {:text, body}, state} -> {:reply, json_decode!(body), state}
      other -> other
    end
  end

  test "two users join server" do
    info_hash = make_id()

    peer1_id = "peer-1______________"
    peer1_offers = for _ <- 0..2, do: make_offer()
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
          offers: peer1_offers
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
end
