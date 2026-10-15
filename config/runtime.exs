import Config

config :webtorrent_tracker, port: String.to_integer(System.get_env("PORT", "4000"))
