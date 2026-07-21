import Config

config :mafia, Mafia.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: System.get_env("POSTGRES_DATABASE", "mafia_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

secret_key_base =
  "5fydPMtV7qG2Jd9k0hQx8AViNw4ScLaUmz6R1eBXK3pWTYHn7bFo2CjE9sDgZrMx"

config :mafia, :secret_key_base, secret_key_base

config :mafia, MafiaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4001"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: secret_key_base,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:mafia, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:mafia, ~w(--watch)]}
  ]

config :mafia, MafiaWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/mafia_web/(controllers|live|components|router)/?.*\.(ex|heex)$"
    ]
  ]

config :mafia, dev_routes: true

config :logger, :default_formatter,
  format: "\n$time [$level] $message $metadata\n",
  metadata: [:request_id, :user_id, :mafia_game_id],
  colors: [enabled: true]

config :logger, level: String.to_existing_atom(System.get_env("LOG_LEVEL", "debug"))
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
