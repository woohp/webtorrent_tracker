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
    {:ok, state} = UserSocket.init([])
    state
  end

  defp send_message(message, state) do
    case UserSocket.handle_in({json_encode!(message), [opcode: :text]}, state) do
      {:push, {:text, body}, state} -> {:reply, json_decode!(body), state}
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

  defp assert_stops(message) do
    assert {:stop, :normal, _state} = UserSocket.handle_in({json_encode!(message), [opcode: :text]}, create_state())
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp websocket_handshake(port) do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false, packet: :raw])

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request =
      "GET / HTTP/1.1\r\n" <>
        "Host: localhost:#{port}\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n\r\n"

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    :ok = :gen_tcp.close(socket)
    response
  end

  test "rejects malformed messages" do
    valid_id = make_id()
    unicode_id = String.duplicate("é", 20)

    assert {:stop, :normal, _state} = UserSocket.handle_in({"not json", [opcode: :text]}, create_state())
    assert_stops(%{"action" => "unknown"})
    assert_stops(%{"action" => "announce", "info_hash" => valid_id, "peer_id" => valid_id, "event" => "bogus"})
    assert_stops(%{"action" => "announce", "info_hash" => String.duplicate("x", 19), "peer_id" => valid_id})

    assert {:reply, _reply, _state} =
             send_message(%{"action" => "announce", "info_hash" => valid_id, "peer_id" => unicode_id}, create_state())

    assert_stops(%{"action" => "announce", "info_hash" => valid_id, "peer_id" => valid_id, "answer" => %{}})
    assert_stops(%{"action" => "scrape", "info_hash" => 123})
    assert_stops(%{"action" => "scrape", "info_hash" => [valid_id, String.duplicate("x", 19)]})
  end

  test "rejects answers to unknown peers" do
    info_hash = make_id()
    {:ok, {_peer_id, _reply, state}} = new_peer(1, info_hash, %{offers: []})

    assert {:stop, :normal, _state} =
             send_message(
               %{
                 "action" => "announce",
                 "info_hash" => info_hash,
                 "peer_id" => "peer-1______________",
                 "to_peer_id" => "unknown_____________",
                 "offer_id" => "offer-1",
                 "answer" => %{"type" => "answer", "sdp" => "valid"}
               },
               state
             )
  end

  test "websocket upgrades work through Bandit" do
    port = free_port()
    {:ok, pid} = Bandit.start_link(plug: WebtorrentTrackerWeb.Endpoint, port: port, startup_log: false)

    response = websocket_handshake(port)

    assert response =~ "HTTP/1.1 101"
    assert response =~ "upgrade: websocket"

    Process.exit(pid, :normal)
  end

  test "invalid websocket upgrades return 400" do
    conn =
      Plug.Test.conn("GET", "/")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> WebtorrentTrackerWeb.UserSocketPlug.call([])

    assert conn.halted
    assert conn.status == 400
    assert conn.resp_body == "invalid websocket upgrade"
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

  test "honors numwant when relaying offers" do
    info_hash = make_id()
    {:ok, {_peer1_id, _reply1, _state1}} = new_peer(1, info_hash, %{offers: []})
    {:ok, {_peer2_id, _reply2, _state2}} = new_peer(2, info_hash, %{offers: []})
    assert_receive_nothing(50)

    {:ok, {_peer3_id, _reply3, _state3}} = new_peer(3, info_hash, %{numwant: 1})

    assert %{"action" => "announce", "offer_id" => _offer_id} = receive_json()
    assert_receive_nothing(50)

    {:ok, {_peer4_id, _reply4, _state4}} = new_peer(4, info_hash, %{numwant: 0})
    assert_receive_nothing(50)

    {:ok, {_peer5_id, _reply5, _state5}} = new_peer(5, info_hash, %{numwant: -1})
    assert_receive_nothing(50)
  end

  test "ignores malformed offers" do
    info_hash = make_id()
    {:ok, {_peer1_id, _reply1, _state1}} = new_peer(1, info_hash, %{offers: []})
    assert_receive_nothing(50)

    {:ok, {_peer2_id, _reply2, _state2}} =
      new_peer(2, info_hash, %{
        offers: [
          %{"offer_id" => make_id()},
          %{"offer" => %{}},
          %{"offer_id" => "offer-1", "offer" => %{"type" => "offer", "sdp" => "valid"}}
        ]
      })

    assert %{"action" => "announce", "offer_id" => _offer_id, "offer" => %{"type" => "offer", "sdp" => "valid"}} =
             receive_json()

    assert_receive_nothing(50)
  end

  test "duplicate peer id disconnects the old socket" do
    info_hash = make_id()
    peer_id = "peer-1______________"

    {:reply, _reply, _state1} =
      send_message(
        %{"action" => "announce", "info_hash" => info_hash, "peer_id" => peer_id, "offers" => []},
        create_state()
      )

    {:reply, _reply, _state2} =
      send_message(
        %{"action" => "announce", "info_hash" => info_hash, "peer_id" => peer_id, "offers" => []},
        create_state()
      )

    assert_receive :disconnect
  end

  test "a peer can participate in multiple torrents and stop one" do
    info_hash1 = make_id()
    info_hash2 = make_id()
    peer_id = "peer-1______________"
    state = create_state()

    {:reply, _reply, state} =
      send_message(%{"action" => "announce", "info_hash" => info_hash1, "peer_id" => peer_id, "offers" => []}, state)

    {:reply, _reply, state} =
      send_message(%{"action" => "announce", "info_hash" => info_hash2, "peer_id" => peer_id, "offers" => []}, state)

    assert %{^info_hash1 => %{"incomplete" => 1}, ^info_hash2 => %{"incomplete" => 1}} = scrape()

    {:ok, _state} =
      send_message(
        %{"action" => "announce", "info_hash" => info_hash1, "peer_id" => peer_id, "event" => "stopped"},
        state
      )

    assert %{^info_hash2 => %{"incomplete" => 1}} = scrape()
    refute Map.has_key?(scrape(), info_hash1)
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
    {:reply, _reply, state2} =
      send_message(%{action: "announce", event: "completed", info_hash: info_hash, peer_id: peer2_id}, state2)

    assert %{^info_hash => %{"complete" => 2, "incomplete" => 1}} = scrape()

    # a later regular announce should not downgrade peer2 to incomplete
    send_message(%{action: "announce", info_hash: info_hash, peer_id: peer2_id}, state2)
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

    assert %{^info_hash => %{"complete" => 0, "incomplete" => 0, "downloaded" => 0}} = scrape(info_hash)
  end
end
