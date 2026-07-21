defmodule Mafia.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Mafia.Repo,
      {DNSCluster, query: Application.get_env(:mafia, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Mafia.PubSub},
      {Mafia.RateLimit, clean_period: :timer.minutes(10)},
      {Oban, Application.fetch_env!(:mafia, Oban)},
      MafiaWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Mafia.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MafiaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
