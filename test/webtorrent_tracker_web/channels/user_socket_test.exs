defmodule WebtorrentTrackerWeb.RoomChannelTest do
  use WebtorrentTrackerWeb.ChannelCase
  alias WebtorrentTrackerWeb.UserSocket

  defp make_id(), do: Base.encode64(:rand.bytes(8))

  defp make_offer() do
    %{
      "offer" => %{
        "type" => "offer",
        "sdp" => "v=0\r\no=mozilla...THIS_IS_SDPARTA-91.0.1 1499069384319828683"
      },
      "offer_id" => make_id()
    }
  end

  def create_state() do
    {:cowboy_websocket, nil, state} = UserSocket.init(nil, [])
    state
  end

  def send_message(message, state) do
    UserSocket.websocket_handle({:text, json_encode!(message)}, state)
  end

  setup do
    %{state: create_state()}
  end

  test "gets info from server on join", %{state: state1} do
    info_hash = make_id()
    peer1_id = "peer-1"

    peer1_offers = [
      make_offer(),
      make_offer(),
      make_offer()
    ]

    {:reply, {:text, out_body}, state1} =
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
           } = json_decode!(out_body)

    assert_receive_nothing()

    # a new peer shows up!
    peer2_id = "peer-2"

    peer2_offers = [
      make_offer(),
      make_offer()
    ]

    state2 = create_state()

    {:reply, {:text, out_body}, _state2} =
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
           } = json_decode!(out_body)

    assert Registry.count_match(WebtorrentTracker.PubSub, info_hash, :_) == 2

    %{
      "action" => "announce",
      "info_hash" => ^info_hash,
      "peer_id" => ^peer2_id,
      "offer" => %{
        "sdp" => <<peer2_offer_sdp::binary>>,
        "type" => "offer"
      },
      "offer_id" => <<peer2_offer_id::binary>>
    } =
      receive do
        <<msg::binary>> -> json_decode!(msg)
      end

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
    %{
      "action" => "announce",
      "info_hash" => ^info_hash,
      "peer_id" => ^peer1_id,
      "offer_id" => ^peer2_offer_id,
      "answer" => %{
        "type" => "answer",
        "sdp" => ^peer2_offer_sdp
      }
    } =
      receive do
        <<msg::binary>> -> json_decode!(msg)
      end

    # end of exchange
    assert_receive_nothing()
  end
end
