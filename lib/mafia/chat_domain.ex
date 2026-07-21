defmodule Mafia.ChatDomain do
  @moduledoc false

  use Ash.Domain

  resources do
    resource(Mafia.Chat.Resources.Conversation)
    resource(Mafia.Chat.Resources.ConversationMember)
    resource(Mafia.Chat.Resources.Message)
    resource(Mafia.Chat.Resources.MessageReaction)
  end
end
