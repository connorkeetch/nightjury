defmodule Mafia.GamesDomain do
  @moduledoc """
  Ash Domain for the Mafia side-game.

  A play-by-post Mafia (Werewolf) game: a human moderator runs the game, the
  system automates the mechanical toil (vote counting, the day/night clock,
  muting the dead, gating night conversations). See
  `docs/planning/mafia-side-game.md`.
  """
  use Ash.Domain

  resources do
    resource(Mafia.Games.Resources.MafiaGame)
    resource(Mafia.Games.Resources.MafiaPlayer)
    resource(Mafia.Games.Resources.MafiaVote)
    resource(Mafia.Games.Resources.MafiaNightAction)
    resource(Mafia.Games.Resources.MafiaRuleRevision)
    resource(Mafia.Games.Resources.MafiaNotebook)
  end
end
