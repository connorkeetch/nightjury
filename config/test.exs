import Config

config :bcrypt_elixir, :log_rounds, 1

postgres_host = System.get_env("POSTGRES_HOST", "localhost")

test_database =
  System.get_env("POSTGRES_DATABASE") ||
    "mafia_test_#{:erlang.phash2(Path.expand("..", __DIR__))}"

config :mafia, Mafia.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: postgres_host,
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: test_database,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

if System.get_env("POSTGRES_SSL", "false") == "true" do
  config :mafia, Mafia.Repo, ssl: [verify: :verify_none]
end

config :mafia, Oban,
  repo: Mafia.Repo,
  prefix: "public",
  testing: :manual,
  plugins: [],
  queues: false

secret_key_base =
  "r4GwMf7bLXJx0nYs9C5K1vQt2Hup8DeBZ3SakWV6iRNcFjEoUqPzdA8TmhYl0NxV"

config :mafia, :secret_key_base, secret_key_base

config :mafia, MafiaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: secret_key_base,
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :mafia, :rate_limit, enabled: false

config :phoenix_live_view, enable_expensive_runtime_checks: true
config :phoenix_live_view, :test_warnings, missing_form_id: :raise
