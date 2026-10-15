# WebtorrentTracker agent guide

WebtorrentTracker is a single-node WebSocket tracker for WebTorrent clients, compatible with the `bittorrent-tracker` WebSocket protocol. It is a Bandit server with one plug (`UserSocketPlug`) and one `WebSock` handler (`UserSocket`). There is no web framework, database, or persistence.

Favor simple, maintainable solutions for that scope. Swarm state is in memory and disposable: a restart loses it, and clients rebuild it on their next announce. Do not complicate rare local races, such as counts that briefly include a socket that was told to disconnect but has not exited yet, unless a concrete recurring failure justifies it.

When dependency work is in scope, prefer the latest stable Elixir/OTP and libraries. Update ranges and the lockfile and fix breaking changes rather than preserving compatibility. Do not turn unrelated tasks into dependency upgrades.

## Documentation

Keep `README.md` to an introduction and essential setup. Keep this guide to onboarding, boundaries, and durable, non-obvious decisions; do not duplicate the protocol or walk through the code.

## Architecture decisions

- Phoenix was removed deliberately; the tracker needs only an HTTP upgrade and a WebSocket handler. Do not reintroduce Phoenix, Phoenix.PubSub, or telemetry plumbing without a concrete need.
- Swarm membership and peer lookup are two duplicate-key `Registry`s, both local to one node: `WebtorrentTracker.Swarms` (info hash → `%{peer_id, complete}`) and `WebtorrentTracker.Peers` (peer ID → socket). Keep them separate. A shared key space lets a client announce an info hash equal to another peer's ID and receive that peer's answers.
- Multi-node operation is a non-goal. Clustering would need distributed counts, scrape, and duplicate-peer detection, not just distributed message delivery.
- Sockets relay pre-encoded JSON to each other as plain binaries, which `handle_info/2` pushes unchanged. `:disconnect` tells a socket that a newer connection with the same peer ID replaced it.

## Protocol policy

- IDs (`info_hash`, `peer_id`, `to_peer_id`) are valid when they are exactly 20 **characters**, not bytes. Clients send each raw byte as one character, so non-ASCII bytes arrive as multi-byte UTF-8. Do not "fix" this to `byte_size/1`.
- Malformed or unknown messages close the socket. An answer to an unknown `to_peer_id` is silently dropped instead: the offering peer may have left before the answer arrived.
- Offers are sent at random to other peers in the swarm, filtered by peer ID and capped by `numwant`. An invalid `numwant` sends no offers.

## Commands

- Setup: `mix deps.get`
- Run: `mix run --no-halt` (port from `PORT`, default 4000)
- Tests: `mix test`
- Final check: `mix format && mix compile --warnings-as-errors && mix test`

## Testing conventions

- Most tests drive `UserSocket` callbacks directly, so every simulated peer is the test process. Relayed messages arrive in its mailbox synchronously: use `assert_received`/`refute_received`, not timeouts or sleeps. Because of this, the socket filters offer recipients by peer ID, not pid.
- The registries are global, so tests stay synchronous and give each test fresh info hashes from `make_id/0`.
- The application does not start the HTTP server in tests. Tests that need a real socket start Bandit with `start_supervised!/1` on port 0 and read the port from `ThousandIsland.listener_info/1`.
