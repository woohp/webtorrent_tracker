defmodule WebtorrentTrackerWeb.UserSocketTest do
  # the swarm and peer registries are global
  use ExUnit.Case

  alias WebtorrentTrackerWeb.{UserSocket, UserSocketPlug}

  # every test peer runs in the test process, so relayed messages arrive in its mailbox synchronously

  defp make_id, do: List.to_string(for <<codepoint <- :rand.bytes(20)>>, do: codepoint)

  defp make_offer do
    %{"offer_id" => make_id(), "offer" => %{"type" => "offer", "sdp" => "sdp-#{System.unique_integer()}"}}
  end

  defp create_state do
    {:ok, state} = UserSocket.init([])
    state
  end

  defp send_message(message, state) do
    case UserSocket.handle_in({JSON.encode!(message), [opcode: :text]}, state) do
      {:push, {:text, body}, state} -> {:reply, JSON.decode!(body), state}
      other -> other
    end
  end

  defp new_peer(peer_idx, info_hash, fields \\ %{}) do
    peer_id = "peer-#{peer_idx}______________"

    message =
      Map.merge(
        %{
          "action" => "announce",
          "info_hash" => info_hash,
          "peer_id" => peer_id,
          "numwant" => 5,
          "offers" => for(_ <- 1..3, do: make_offer())
        },
        fields
      )

    {:reply, reply, state} = send_message(message, create_state())
    {peer_id, reply, state}
  end

  defp scrape(fields \\ %{}) do
    {:reply, %{"action" => "scrape", "files" => files}, _state} =
      send_message(Map.put(fields, "action", "scrape"), create_state())

    files
  end

  defp received_json do
    assert_received body when is_binary(body)
    JSON.decode!(body)
  end

  defp assert_stops(message) do
    assert {:stop, :normal, _state} = send_message(message, create_state())
  end

  test "rejects malformed messages" do
    valid_id = make_id()

    assert {:stop, :normal, _state} = UserSocket.handle_in({"not json", [opcode: :text]}, create_state())
    assert_stops(%{"action" => "unknown"})
    assert_stops(%{"action" => "announce", "info_hash" => valid_id, "peer_id" => valid_id, "event" => "bogus"})
    assert_stops(%{"action" => "announce", "info_hash" => String.duplicate("x", 19), "peer_id" => valid_id})
    assert_stops(%{"action" => "announce", "info_hash" => valid_id, "peer_id" => valid_id, "answer" => %{}})
    assert_stops(%{"action" => "scrape", "info_hash" => 123})
    assert_stops(%{"action" => "scrape", "info_hash" => [valid_id, String.duplicate("x", 19)]})
  end

  test "ids are 20 characters, not 20 bytes" do
    assert {_peer_id, %{"action" => "announce"}, _state} =
             new_peer(1, make_id(), %{"peer_id" => String.duplicate("é", 20)})
  end

  test "websocket upgrades work through Bandit" do
    pid = start_supervised!({Bandit, plug: UserSocketPlug, port: 0, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, [
        "GET / HTTP/1.1\r\n",
        "Host: localhost:#{port}\r\n",
        "Connection: Upgrade\r\n",
        "Upgrade: websocket\r\n",
        "Sec-WebSocket-Key: #{Base.encode64(:crypto.strong_rand_bytes(16))}\r\n",
        "Sec-WebSocket-Version: 13\r\n\r\n"
      ])

    {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    assert response =~ "HTTP/1.1 101"
    assert response =~ "upgrade: websocket"
  end

  test "non-websocket requests are rejected" do
    invalid_upgrade =
      Plug.Test.conn("GET", "/")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> UserSocketPlug.call([])

    assert {400, _headers, "invalid websocket upgrade"} = Plug.Test.sent_resp(invalid_upgrade)
    assert {404, _headers, _body} = Plug.Test.sent_resp(UserSocketPlug.call(Plug.Test.conn("GET", "/foo"), []))
  end

  test "two peers exchange an offer and answer" do
    info_hash = make_id()
    {peer1_id, reply1, state1} = new_peer(1, info_hash, %{"offers" => []})

    assert %{"action" => "announce", "info_hash" => ^info_hash, "interval" => 120, "complete" => 0, "incomplete" => 1} =
             reply1

    refute_received _

    [%{"offer_id" => offer_id, "offer" => offer}] = offers = [make_offer()]
    {peer2_id, reply2, _state2} = new_peer(2, info_hash, %{"offers" => offers})
    assert %{"complete" => 0, "incomplete" => 2} = reply2

    assert %{
             "action" => "announce",
             "info_hash" => ^info_hash,
             "peer_id" => ^peer2_id,
             "offer_id" => ^offer_id,
             "offer" => ^offer
           } =
             received_json()

    refute_received _

    answer = %{"type" => "answer", "sdp" => "answer-sdp"}

    assert {:ok, _state1} =
             send_message(
               %{
                 "action" => "announce",
                 "info_hash" => info_hash,
                 "peer_id" => peer1_id,
                 "to_peer_id" => peer2_id,
                 "offer_id" => offer_id,
                 "answer" => answer
               },
               state1
             )

    assert %{
             "action" => "announce",
             "info_hash" => ^info_hash,
             "peer_id" => ^peer1_id,
             "offer_id" => ^offer_id,
             "answer" => ^answer
           } =
             received_json()

    refute_received _
  end

  test "ignores answers to unknown peers" do
    info_hash = make_id()
    {peer_id, _reply, state} = new_peer(1, info_hash, %{"offers" => []})

    assert {:ok, _state} =
             send_message(
               %{
                 "action" => "announce",
                 "info_hash" => info_hash,
                 "peer_id" => peer_id,
                 "to_peer_id" => "unknown_____________",
                 "offer_id" => "offer-1",
                 "answer" => %{"type" => "answer", "sdp" => "valid"}
               },
               state
             )

    refute_received _
  end

  test "scrapes all swarms or the requested ones" do
    info_hash = make_id()
    unknown_info_hash = make_id()
    new_peer(1, info_hash, %{"offers" => []})
    new_peer(2, info_hash, %{"offers" => []})

    swarm = %{"complete" => 0, "incomplete" => 2, "downloaded" => 0}
    empty = %{"complete" => 0, "incomplete" => 0, "downloaded" => 0}

    assert %{^info_hash => ^swarm} = scrape()
    assert scrape(%{"info_hash" => unknown_info_hash}) == %{unknown_info_hash => empty}
    assert scrape(%{"info_hash" => [info_hash, unknown_info_hash]}) == %{info_hash => swarm, unknown_info_hash => empty}
  end

  test "honors numwant when relaying offers" do
    info_hash = make_id()
    new_peer(1, info_hash, %{"offers" => []})
    new_peer(2, info_hash, %{"offers" => []})

    new_peer(3, info_hash, %{"numwant" => 1})
    assert %{"action" => "announce", "offer_id" => _offer_id} = received_json()
    refute_received _

    new_peer(4, info_hash, %{"numwant" => 0})
    new_peer(5, info_hash, %{"numwant" => -1})
    refute_received _
  end

  test "ignores malformed offers" do
    info_hash = make_id()
    new_peer(1, info_hash, %{"offers" => []})

    valid_offer = %{"offer_id" => "offer-1", "offer" => %{"type" => "offer", "sdp" => "valid"}}
    new_peer(2, info_hash, %{"offers" => [%{"offer_id" => make_id()}, %{"offer" => %{}}, valid_offer]})

    assert %{"offer_id" => "offer-1", "offer" => %{"type" => "offer", "sdp" => "valid"}} = received_json()
    refute_received _
  end

  test "a duplicate peer id disconnects the old socket" do
    info_hash = make_id()
    {_peer_id, _reply, old_state} = new_peer(1, info_hash, %{"offers" => []})
    new_peer(1, info_hash, %{"offers" => []})

    assert_received :disconnect
    assert {:stop, :normal, _state} = UserSocket.handle_info(:disconnect, old_state)
  end

  test "completed peers" do
    info_hash = make_id()
    {_peer1_id, reply1, _state1} = new_peer(1, info_hash, %{"event" => "completed"})
    {_peer2_id, reply2, _state2} = new_peer(2, info_hash, %{"event" => "started"})
    {_peer3_id, reply3, _state3} = new_peer(3, info_hash)
    {_peer4_id, reply4, _state4} = new_peer(4, info_hash, %{"event" => "completed"})

    assert %{"complete" => 1, "incomplete" => 0} = reply1
    assert %{"complete" => 1, "incomplete" => 1} = reply2
    assert %{"complete" => 1, "incomplete" => 2} = reply3
    assert %{"complete" => 2, "incomplete" => 2} = reply4
    assert %{^info_hash => %{"complete" => 2, "incomplete" => 2, "downloaded" => 2}} = scrape()
  end

  test "client starts and then completes" do
    info_hash = make_id()
    new_peer(1, info_hash, %{"event" => "completed"})
    {peer2_id, _reply2, state2} = new_peer(2, info_hash, %{"event" => "started"})
    new_peer(3, info_hash)
    assert %{^info_hash => %{"complete" => 1, "incomplete" => 2}} = scrape()

    announce = %{"action" => "announce", "info_hash" => info_hash, "peer_id" => peer2_id}
    {:reply, _reply, state2} = send_message(Map.put(announce, "event", "completed"), state2)
    assert %{^info_hash => %{"complete" => 2, "incomplete" => 1}} = scrape()

    # a later regular announce should not downgrade peer2 to incomplete
    send_message(announce, state2)
    assert %{^info_hash => %{"complete" => 2, "incomplete" => 1}} = scrape()
  end

  test "stopping one torrent leaves the peer's other torrents" do
    info_hash1 = make_id()
    info_hash2 = make_id()
    {peer_id, _reply, state} = new_peer(1, info_hash1, %{"event" => "completed"})
    announce = %{"action" => "announce", "info_hash" => info_hash2, "peer_id" => peer_id}
    {:reply, _reply, state} = send_message(announce, state)
    assert %{^info_hash1 => %{"complete" => 1}, ^info_hash2 => %{"incomplete" => 1}} = scrape()

    assert {:ok, _state} = send_message(Map.merge(announce, %{"info_hash" => info_hash1, "event" => "stopped"}), state)

    files = scrape()
    refute Map.has_key?(files, info_hash1)
    assert %{^info_hash2 => %{"complete" => 0, "incomplete" => 1}} = files
  end
end
