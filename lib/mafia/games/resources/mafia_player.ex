defmodule Mafia.Games.Resources.MafiaPlayer do
  @moduledoc """
  A seat in a Mafia game: the join between a user and a `MafiaGame`, plus their
  assigned role.

  A role is a moderator-authored label and private brief; night effects stay
  moderator-resolved. `alignment` is a free-form faction label, while `status`
  plus capability overrides determine what this seat may do. The host remains a
  neutral overseer rather than a player.
  """
  use Ash.Resource,
    domain: Mafia.GamesDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("mafia_players")
    repo(Mafia.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :role_name, :string do
      allow_nil?(true)
      constraints(max_length: 100)
      description("Free-text role label the mod assigns (\"Cop\", \"Goon\", \"Vanilla Townie\")")
    end

    attribute :alignment, :string do
      allow_nil?(true)
      constraints(max_length: 100)
      description("Free-form faction label; nil until the moderator assigns one")
    end

    attribute :role_pm_body, :string do
      allow_nil?(true)
      constraints(max_length: 5_000)
      description("Mod-written role PM the system delivers to the player")
    end

    attribute(:is_alive, :boolean, allow_nil?: false, default: true)

    attribute :status, :string do
      allow_nil?(false)
      default("active")
    end

    attribute :tags, {:array, :string} do
      allow_nil?(false)
      default([])
      constraints(max_length: 50, items: [max_length: 60])
    end

    attribute(:capability_overrides, :map, allow_nil?: false, default: %{})
    attribute(:eliminated_phase, :integer, allow_nil?: true)

    attribute :eliminated_by, :atom do
      allow_nil?(true)
      constraints(one_of: [:lynch, :night, :modkill])
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :mafia_game, Mafia.Games.Resources.MafiaGame do
      allow_nil?(false)
      attribute_writable?(true)
      attribute_type(:uuid)
    end

    belongs_to :user, Mafia.Accounts.Resources.User do
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_player, [:mafia_game_id, :user_id])
  end

  policies do
    bypass actor_attribute_equals(:is_admin, true) do
      authorize_if(always())
    end

    policy action_type(:read) do
      authorize_if(always())
    end

    # A user joins themselves; the mod adds players. Lobby rules are enforced in
    # the `Mafia.Games` context; system callers use `authorize?: false`.
    policy action_type(:create) do
      authorize_if(actor_present())
    end

    # Mod (game host) manages roles/eliminations; a player may remove themselves.
    policy action_type([:update, :destroy]) do
      authorize_if(expr(mafia_game.host_id == ^actor(:id)))
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(expr(is_nil(^actor(:id))))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :mafia_game_id,
        :user_id,
        :role_name,
        :alignment,
        :role_pm_body,
        :status,
        :tags,
        :capability_overrides
      ])
    end

    update :update do
      accept([
        :role_name,
        :alignment,
        :role_pm_body,
        :is_alive,
        :status,
        :tags,
        :capability_overrides,
        :eliminated_phase,
        :eliminated_by
      ])
    end
  end
end
