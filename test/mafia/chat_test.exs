defmodule Mafia.ChatTest do
  use Mafia.DataCase, async: true

  alias Mafia.Chat
  alias Mafia.Fixtures

  test "members can chat and a shadow-muted member cannot add or remove reactions" do
    host = Fixtures.user_fixture()
    player = Fixtures.user_fixture()

    assert {:ok, conversation} =
             Chat.create_group_conversation(host.id, [player.id],
               title: "Town Square",
               metadata: %{"mafia_game_id" => Ecto.UUID.generate(), "channel" => "day_thread"}
             )

    assert {:ok, message} = Chat.send_message(conversation.id, host.id, "Opening post")
    assert {:ok, reaction} = Chat.toggle_reaction(message.id, player.id, "👍")
    assert reaction.emoji == "👍"

    assert {:ok, _member} =
             Chat.shadow_mute_member(conversation.id, host.id, player.id, true)

    assert {:error, :muted} = Chat.toggle_reaction(message.id, player.id, "👍")
    assert {:error, :muted} = Chat.toggle_reaction(message.id, player.id, "❤️")

    assert {:ok, [loaded]} = Chat.list_messages(conversation.id, player.id)
    assert Enum.any?(loaded.reactions, &(&1.id == reaction.id))
  end

  test "a locked day thread rejects player posts but permits moderator narration" do
    host = Fixtures.user_fixture()
    player = Fixtures.user_fixture()

    {:ok, conversation} =
      Chat.create_group_conversation(host.id, [player.id],
        metadata: %{"mafia_game_id" => Ecto.UUID.generate()}
      )

    assert {:ok, _} = Chat.set_conversation_read_only(conversation.id, host.id, true)
    assert {:error, :read_only} = Chat.send_message(conversation.id, player.id, "Too late")
    assert {:ok, _} = Chat.send_message(conversation.id, host.id, "Night falls", system: true)
  end
end
