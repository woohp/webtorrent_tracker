defmodule WebtorrentTrackerWeb.RoomChannelTest do
  use WebtorrentTrackerWeb.ChannelCase
  alias Phoenix.Socket.Message

  defp make_id(), do: :rand.bytes(8)

  defp make_offer() do
    %{
      "offer" => %{
        "type" => "offer",
        "sdp" => "v=0\r\no=mozilla...THIS_IS_SDPARTA-91.0.1 1499069384319828683"
      },
      "offer_id" => make_id()
    }
  end

  setup do
    %{socket: socket(WebtorrentTrackerWeb.UserSocket)}
  end

  test "gets info from server on join", %{socket: socket1} do
    info_hash = make_id()
    peer1_id = "peer-1"

    peer1_offers = [
      make_offer(),
      make_offer(),
      make_offer()
    ]

    {:ok, reply, socket1} =
      subscribe_and_join(socket1, WebtorrentTrackerWeb.RoomChannel, info_hash, %{
        action: "announce",
        info_hash: info_hash,
        peer_id: peer1_id,
        numwant: 5,
        downloaded: 0,
        uploaded: 0,
        offers: peer1_offers
      })

    assert %{
             action: "announce",
             info_hash: ^info_hash,
             interval: 120,
             complete: 0,
             incomplete: 1
           } = reply

    assert_broadcast "announce", %{
      action: "announce",
      info_hash: ^info_hash,
      peer_id: ^peer1_id,
      offer: %{
        "sdp" => <<_sdp::binary>>,
        "type" => "offer"
      },
      offer_id: <<_offer_id::binary>>
    }

    assert_receive_nothing()

    # a new peer shows up!
    peer2_id = "peer-2"

    peer2_offers = [
      make_offer(),
      make_offer()
    ]

    socket2 = socket(WebtorrentTrackerWeb.UserSocket)

    {:ok, reply, socket2} =
      subscribe_and_join(socket, WebtorrentTrackerWeb.RoomChannel, info_hash, %{
        action: "announce",
        info_hash: info_hash,
        peer_id: peer2_id,
        numwant: 5,
        downloaded: 0,
        uploaded: 0,
        offers: peer2_offers
      })

    assert %{
             action: "announce",
             info_hash: ^info_hash,
             interval: 120,
             complete: 0,
             incomplete: 1
           } = reply

    assert_receive %Message{
      payload:
        %{
          action: "announce",
          info_hash: ^info_hash,
          peer_id: ^peer2_id,
          offer: %{
            "sdp" => <<peer2_offer_sdp::binary>>,
            "type" => "offer"
          },
          offer_id: <<peer2_offer_id::binary>>
        } = payload
    }

    assert peer2_offer_id in Enum.map(peer2_offers, fn offer -> offer["offer_id"] end)

    for _ <- 0..1 do
      assert_broadcast "announce", ^payload
    end

    # at this point, peer1 have received the offer from peer2, and responds with an answer
    push(socket1, "announce", %{
      "action" => "announce",
      "info_hash" => info_hash,
      "peer_id" => peer1_id,
      "to_peer_id" => peer2_id,
      "offer_id" => peer2_offer_id,
      "answer" => %{
        "type" => "answer",
        "sdp" => peer2_offer_sdp
      }
    })

    # and peer2 should get the answer from peer1
    assert_receive %{
      event: "announce",
      payload: %{
        "action" => "announce",
        "info_hash" => info_hash,
        "peer_id" => peer1_id,
        "offer_id" => peer2_offer_id,
        "answer" => %{
          "type" => "answer",
          "sdp" => ^peer2_offer_sdp
        }
      }
    }

    # end of exchange
    assert_receive_nothing()
  end

  # test "ping replies with status ok", %{socket: socket} do
  #   ref = push socket, "ping", %{"hello" => "there"}
  #   assert_reply ref, :ok, %{"hello" => "there"}
  # end

  # test "shout broadcasts to room:lobby", %{socket: socket} do
  #   push socket, "shout", %{"hello" => "all"}
  #   assert_broadcast "shout", %{"hello" => "all"}
  # end

  # test "broadcasts are pushed to the client", %{socket: socket} do
  #   broadcast_from! socket, "broadcast", %{"some" => "data"}
  #   assert_push "broadcast", %{"some" => "data"}
  # end
end
