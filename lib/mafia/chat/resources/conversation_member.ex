defmodule Mafia.Chat.Resources.ConversationMember do
  @moduledoc false

  use Ash.Resource,
    domain: Mafia.ChatDomain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("conversation_members")
    repo(Mafia.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :role, :atom do
      allow_nil?(false)
      default(:member)
      constraints(one_of: [:admin, :member, :spectator])
    end

    attribute(:last_read_message_id, :uuid)
    attribute(:is_muted, :boolean, allow_nil?: false, default: false)
    attribute(:is_pinned, :boolean, allow_nil?: false, default: false)
    attribute(:shadow_muted, :boolean, allow_nil?: false, default: false)
    attribute(:hidden_at, :utc_datetime_usec)
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
  end

  identities do
    identity(:unique_member, [:conversation_id, :user_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:conversation_id, :user_id, :role])
    end

    update :update do
      primary?(true)
      accept([:last_read_message_id, :is_muted, :is_pinned, :shadow_muted, :hidden_at])
      require_atomic?(false)
    end
  end
end
