# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

dispatch = [
  {:_,
   [
     {"/", WebtorrentTrackerWeb.UserSocket, []},
     {:_, Phoenix.Endpoint.Cowboy2Handler, {WebtorrentTrackerWeb.Endpoint, []}}
   ]}
]

# Configures the endpoint
config :webtorrent_tracker, WebtorrentTrackerWeb.Endpoint,
  http: [dispatch: dispatch],
  pubsub_server: WebtorrentTracker.PubSub

config :webtorrent_tracker, WebtorrentTrackerWeb.UserSocket, pubsub_server: WebtorrentTracker.PubSub

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
