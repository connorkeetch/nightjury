defmodule Mafia.Games.Resources.MafiaVote do
  @moduledoc """
  A day-phase lynch vote. One live vote per (game, phase, voter) — the unique
  identity makes "change your vote" an upsert and "unvote" a delete. A null
  `target_player_id` is an explicit "No Lynch".

  Integrity (voter alive, phase open, before deadline) is enforced in the
  `Mafia.Games` context at cast time, mirroring `Chat.send_message`'s
  `verify_can_send` approach.
  """
  use Ash.Resource,
    domain: Mafia.GamesDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("mafia_votes")
    repo(Mafia.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:phase_number, :integer, allow_nil?: false)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :mafia_game, Mafia.Games.Resources.MafiaGame do
      allow_nil?(false)
      attribute_writable?(true)
      attribute_type(:uuid)
    end

    belongs_to :voter, Mafia.Games.Resources.MafiaPlayer do
      allow_nil?(false)
      attribute_writable?(true)
      attribute_type(:uuid)
      source_attribute(:voter_player_id)
    end

    belongs_to :target, Mafia.Games.Resources.MafiaPlayer do
      allow_nil?(true)
      attribute_writable?(true)
      attribute_type(:uuid)
      source_attribute(:target_player_id)
    end
  end

  identities do
    identity(:one_vote_per_phase, [:mafia_game_id, :phase_number, :voter_player_id])
  end

  policies do
    bypass actor_attribute_equals(:is_admin, true) do
      authorize_if(always())
    end

    policy action_type(:read) do
      authorize_if(always())
    end

    # The voter owns their vote. Host/admin and system callers are also allowed.
    policy action_type([:create, :update, :destroy]) do
      authorize_if(expr(voter.user_id == ^actor(:id)))
      authorize_if(expr(mafia_game.host_id == ^actor(:id)))
      authorize_if(expr(is_nil(^actor(:id))))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:mafia_game_id, :phase_number, :voter_player_id, :target_player_id])
    end

    update :update do
      accept([:target_player_id])
    end
  end
end
