defmodule Mafia.Workers.MafiaReconcilerWorker do
  @moduledoc """
  Hourly backstop for the Mafia phase clock.

  A single `MafiaPhaseWorker` job scheduled up to 24h out has no self-healing: if
  it is lost (a Railway redeploy near the firing time, a cancelled/pruned job),
  nothing reschedules it and the game would stall forever. This reconciler scans
  for games whose deadline has passed and force-advances them — resolving overdue
  Days and nudging overdue Nights. See `docs/planning/mafia-side-game.md`.

  Runs via Oban cron (configured in config.exs).
  """
  use Oban.Worker, queue: :mafia, max_attempts: 3

  require Ash.Query
  require Logger
  alias Mafia.Games
  alias Mafia.Games.Resources.MafiaGame

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    overdue =
      MafiaGame
      |> Ash.Query.filter(
        status in [:day, :night] and not is_nil(phase_ends_at) and phase_ends_at < ^now
      )
      |> Ash.read!(authorize?: false)

    if overdue != [] do
      Logger.info("Mafia reconciler advancing overdue phases", count: length(overdue))
    end

    Enum.each(overdue, fn game ->
      case game.status do
        :day -> Games.resolve_day(game)
        :night -> Games.nudge_night_overdue(game)
      end
    end)

    :ok
  end
end
