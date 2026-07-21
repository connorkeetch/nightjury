import Config

config :mafia, MafiaWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  force_ssl: [rewrite_on: [:x_forwarded_proto], hsts: true]

config :logger, level: :info
