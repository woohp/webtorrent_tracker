import Config

if config_env() == :prod do
  config :logger, level: :info
end

if config_env() == :test do
  # tests start their own server on a free port
  config :webtorrent_tracker, server: false
  config :logger, level: :warning
end
