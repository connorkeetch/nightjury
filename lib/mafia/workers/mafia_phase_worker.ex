defmodule Mafia.Workers.MafiaPhaseWorker do
  @moduledoc """
  Fires at a Mafia phase deadline.

  - **Day** → auto-resolve the lynch and advance to Night (`Games.resolve_day/1`).
  - **Night** → nudge the mod that night is overdue (night resolution is manual;
    there is no auto-resolver in v1).

  Idempotent: the job is unique per `{mafia_game_id, phase_number}`, and the
  perform clause no-ops unless the game is still on the scheduled phase — so a
  stale timer (e.g. after a hammer ended the day early) does nothing. The hourly
  `MafiaReconcilerWorker` is the backstop if this one-shot job is ever lost
  (a Railway redeploy, a cancelled job).
  """
  use Oban.Worker,
    queue: :mafia,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:mafia_game_id, :phase_number]]

  alias Mafia.Games

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mafia_game_id" => game_id, "phase_number" => phase_number}}) do
    case Games.get_game(game_id) do
      {:ok, %{phase_number: ^phase_number, status: :day} = game} ->
        Games.resolve_day(game)

      {:ok, %{phase_number: ^phase_number, status: :night} = game} ->
        Games.nudge_night_overdue(game)

      _ ->
        # Stale phase, finished, or deleted — nothing to do.
        :ok
    end
  end
end
