defmodule Mafia.Games.Resources.MafiaNotebook do
  @moduledoc "A player's private, per-game notebook."

  use Ash.Resource,
    domain: Mafia.GamesDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("mafia_notebooks")
    repo(Mafia.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :body, :string do
      allow_nil?(false)
      default("")
      constraints(max_length: 20_000, allow_empty?: true)
    end

    attribute(:player_notes, :map, allow_nil?: false, default: %{})
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
    identity(:unique_game_user, [:mafia_game_id, :user_id])
  end

  policies do
    policy action_type([:read, :create, :update]) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(expr(is_nil(^actor(:id))))
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:mafia_game_id, :user_id, :body, :player_notes])
    end

    update :update do
      accept([:body, :player_notes])
    end
  end
end
