# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
use Mix.Config

# Configures the endpoint
config :webtorrent_tracker, WebtorrentTrackerWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "jpvO1i7zFbtIHDE1N9kgr/Z45h8eCI1MQwHHm9JfMMx5EIZNudYXwFByUBZiRiNZ",
  render_errors: [],
  pubsub_server: WebtorrentTracker.PubSub,
  live_view: [signing_salt: "j8J1EhxD"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
