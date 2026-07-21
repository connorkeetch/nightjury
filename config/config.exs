import Config

config :phoenix_live_view, :colocated_assets, disable_symlink_warning: true

config :ash, :missed_notifications, :ignore

config :mafia,
  ecto_repos: [Mafia.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [Mafia.AccountsDomain, Mafia.ChatDomain, Mafia.GamesDomain]

config :mafia, :writes_enabled, true

config :mafia, MafiaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MafiaWeb.ErrorHTML, json: MafiaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Mafia.PubSub,
  live_view: [signing_salt: "mF4Q8x2K"]

config :esbuild,
  version: "0.25.4",
  mafia: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.7",
  mafia: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :user_id, :mafia_game_id]

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "token", "secret"]

config :mafia, :rate_limit, enabled: true

config :mafia, Oban,
  repo: Mafia.Repo,
  prefix: "public",
  notifier: Oban.Notifiers.PG,
  peer: Oban.Peers.Global,
  shutdown_grace_period: :timer.seconds(30),
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Mafia.Workers.MafiaReconcilerWorker}
     ]},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7, interval: :timer.hours(1)}
  ],
  queues: [default: 1, notifications: 1, mafia: 1]

import_config "#{config_env()}.exs"
