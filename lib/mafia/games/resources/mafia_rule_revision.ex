defmodule Mafia.Games.Resources.MafiaRuleRevision do
  @moduledoc "An immutable snapshot of a moderator-authored rules change."

  use Ash.Resource,
    domain: Mafia.GamesDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("mafia_rule_revisions")
    repo(Mafia.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:revision, :integer, allow_nil?: false)
    attribute(:ruleset, :map, allow_nil?: false)

    attribute :summary, :string do
      allow_nil?(false)
      default("")
      constraints(max_length: 500, allow_empty?: true)
    end

    attribute(:phase_number, :integer, allow_nil?: false, default: 0)

    attribute :status, :string do
      allow_nil?(false)
      default("setup")
      constraints(max_length: 20)
    end

    create_timestamp(:created_at)
  end

  relationships do
    belongs_to :mafia_game, Mafia.Games.Resources.MafiaGame do
      allow_nil?(false)
      attribute_writable?(true)
      attribute_type(:uuid)
    end

    belongs_to :changed_by, Mafia.Accounts.Resources.User do
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_game_revision, [:mafia_game_id, :revision])
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type(:create) do
      authorize_if(expr(mafia_game.host_id == ^actor(:id)))
      authorize_if(expr(is_nil(^actor(:id))))
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :mafia_game_id,
        :changed_by_id,
        :revision,
        :ruleset,
        :summary,
        :phase_number,
        :status
      ])
    end
  end
end
