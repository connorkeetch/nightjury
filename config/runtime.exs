import Config

if config_env() == :prod or System.get_env("PHX_SERVER") do
  config :mafia, MafiaWeb.Endpoint, server: true
end

if config_env() == :prod do
  config :mafia, :writes_enabled, System.get_env("MAFIA_WRITES_ENABLED", "false") == "true"

  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is missing"

  database_host = URI.parse(database_url).host || ""

  socket_options =
    if String.contains?(database_host, ".railway.internal"), do: [:inet6], else: []

  config :mafia, Mafia.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    socket_options: socket_options ++ [keepalive: true, nodelay: true]

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is missing"

  host =
    System.get_env("PHX_HOST") ||
      raise "PHX_HOST is missing"

  port = String.to_integer(System.get_env("PORT", "4000"))
  railway_domain = System.get_env("RAILWAY_PUBLIC_DOMAIN")

  check_origin =
    ["//#{host}", railway_domain && "//#{railway_domain}"]
    |> Enum.reject(&is_nil/1)

  config :mafia, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :mafia, :secret_key_base, secret_key_base

  config :mafia, MafiaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: check_origin,
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
end
