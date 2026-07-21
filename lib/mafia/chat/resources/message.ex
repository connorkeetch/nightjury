defmodule Mafia.Chat.Resources.Message do
  @moduledoc false

  use Ash.Resource,
    domain: Mafia.ChatDomain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("messages")
    repo(Mafia.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :body, :string do
      allow_nil?(false)
      constraints(max_length: 10_000, allow_empty?: true)
    end

    attribute(:reply_to_message_id, :uuid)
    attribute(:json_metadata, :map, default: %{})
    attribute(:attachments, {:array, :map}, default: [])
    attribute(:deleted_at, :utc_datetime_usec)
    attribute(:edited_at, :utc_datetime_usec)
    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :conversation, Mafia.Chat.Resources.Conversation do
      allow_nil?(false)
      attribute_writable?(true)
    end

    belongs_to :user, Mafia.Accounts.Resources.User do
      allow_nil?(false)
      attribute_writable?(true)
    end

    has_many :reactions, Mafia.Chat.Resources.MessageReaction
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      accept([
        :conversation_id,
        :user_id,
        :body,
        :reply_to_message_id,
        :json_metadata,
        :attachments
      ])
    end

    update :update do
      primary?(true)
      accept([:body, :deleted_at, :edited_at])
      require_atomic?(false)
    end
  end
end
