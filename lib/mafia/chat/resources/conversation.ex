defmodule Mafia.Chat.Resources.Conversation do
  @moduledoc false

  use Ash.Resource,
    domain: Mafia.ChatDomain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("conversations")
    repo(Mafia.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :kind, :atom do
      allow_nil?(false)
      default(:group)
      constraints(one_of: [:direct, :group, :game])
    end

    attribute(:title, :string)
    attribute(:is_archived, :boolean, allow_nil?: false, default: false)
    attribute(:game_id, :uuid)
    attribute(:metadata, :map, default: %{})
    attribute(:is_read_only, :boolean, allow_nil?: false, default: false)
    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :creator, Mafia.Accounts.Resources.User do
      allow_nil?(false)
      attribute_writable?(true)
    end

    has_many :members, Mafia.Chat.Resources.ConversationMember
    has_many :messages, Mafia.Chat.Resources.Message
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:kind, :title, :game_id, :metadata, :creator_id])
    end

    update :update do
      primary?(true)
      accept([:title, :is_archived, :is_read_only])
      require_atomic?(false)
    end
  end
end
