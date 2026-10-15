# WebtorrentTracker

A WebSocket tracker for [WebTorrent](https://webtorrent.io) clients. It speaks the `bittorrent-tracker` WebSocket protocol (announce, WebRTC offer/answer relay, and scrape) and keeps all swarm state in memory.

## Running

```sh
mix deps.get
mix run --no-halt
```

The tracker listens on port 4000 (override with `PORT`). Point clients at `ws://localhost:4000`.
