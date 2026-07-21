defmodule Mafia.Chat.Resources.MessageReaction do
  @moduledoc false

  use Ash.Resource,
    domain: Mafia.ChatDomain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("message_reactions")
    repo(Mafia.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:emoji, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 20])
    create_timestamp(:created_at)
  end

  relationships do
    belongs_to :message, Mafia.Chat.Resources.Message do
      allow_nil?(false)
      attribute_writable?(true)
    end

    belongs_to :user, Mafia.Accounts.Resources.User do
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_user_emoji, [:message_id, :user_id, :emoji])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:message_id, :user_id, :emoji])
    end
  end
end
