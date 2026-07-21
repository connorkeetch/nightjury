defmodule Mafia.Games.Resources.MafiaNightAction do
  @moduledoc """
  A night-action SUBMISSION. This resource COLLECTS actions only — it does not
  resolve them. The mod reads the queue and resolves the night by hand, writing
  the outcome into `mod_result`. (An auto-resolver is explicitly out of scope for
  v1; see `docs/planning/mafia-side-game.md`.)

  Reads are restricted: only the submitting player and the mod (game host) can
  see a night action.
  """
  use Ash.Resource,
    domain: Mafia.GamesDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("mafia_night_actions")
    repo(Mafia.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:phase_number, :integer, allow_nil?: false)

    attribute :action_kind, :string do
      allow_nil?(false)
      constraints(max_length: 60)
      description("Free-text ability label (\"investigate\", \"protect\", \"kill\")")
    end

    attribute :mod_result, :string do
      allow_nil?(true)
      constraints(max_length: 5_000)
      description("The outcome the mod records after resolving by hand")
    end

    attribute(:resolved, :boolean, allow_nil?: false, default: false)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :mafia_game, Mafia.Games.Resources.MafiaGame do
      allow_nil?(false)
      attribute_writable?(true)
      attribute_type(:uuid)
    end

    belongs_to :actor_player, Mafia.Games.Resources.MafiaPlayer do
      allow_nil?(false)
      attribute_writable?(true)
      attribute_type(:uuid)
      source_attribute(:actor_player_id)
    end

    belongs_to :target_player, Mafia.Games.Resources.MafiaPlayer do
      allow_nil?(true)
      attribute_writable?(true)
      attribute_type(:uuid)
      source_attribute(:target_player_id)
    end
  end

  identities do
    identity(:one_action_per_kind, [:mafia_game_id, :phase_number, :actor_player_id, :action_kind])
  end

  policies do
    bypass actor_attribute_equals(:is_admin, true) do
      authorize_if(always())
    end

    # Secret: only the submitter and the mod can read a night action.
    policy action_type(:read) do
      authorize_if(expr(actor_player.user_id == ^actor(:id)))
      authorize_if(expr(mafia_game.host_id == ^actor(:id)))
      authorize_if(expr(is_nil(^actor(:id))))
    end

    # The submitting player creates/edits their own action.
    policy action_type([:create, :destroy]) do
      authorize_if(expr(actor_player.user_id == ^actor(:id)))
      authorize_if(expr(mafia_game.host_id == ^actor(:id)))
      authorize_if(expr(is_nil(^actor(:id))))
    end

    # The mod resolves; the submitter may still edit their own pending action.
    policy action_type(:update) do
      authorize_if(expr(mafia_game.host_id == ^actor(:id)))
      authorize_if(expr(actor_player.user_id == ^actor(:id)))
      authorize_if(expr(is_nil(^actor(:id))))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:mafia_game_id, :phase_number, :actor_player_id, :action_kind, :target_player_id])
    end

    update :update do
      accept([:action_kind, :target_player_id, :mod_result, :resolved])
    end

    update :resolve do
      description("Mod records the outcome of a night action")
      accept([:mod_result])
      change(set_attribute(:resolved, true))
    end
  end
end
