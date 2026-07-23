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

  test "archiving a conversation closes direct reads, posts, and reactions" do
    host = Fixtures.user_fixture()
    player = Fixtures.user_fixture()

    assert {:ok, conversation} = Chat.create_group_conversation(host.id, [player.id])
    assert {:ok, message} = Chat.send_message(conversation.id, player.id, "Before archive")
    assert {:ok, _archived} = Chat.archive_conversation(conversation.id, host.id)

    assert {:error, :not_found} =
             Chat.get_conversation_for_user(conversation.id, player.id)

    assert {:error, :archived} = Chat.list_messages(conversation.id, player.id)
    assert {:error, :archived} = Chat.send_message(conversation.id, player.id, "Too late")
    assert {:error, :archived} = Chat.toggle_reaction(message.id, player.id, "👍")
  end

  test "messages accept a direct HTTPS GIF and reject unsafe media" do
    sender = Fixtures.user_fixture()
    recipient = Fixtures.user_fixture()
    {:ok, conversation} = Chat.create_group_conversation(sender.id, [recipient.id])

    assert {:error, :invalid_gif} =
             Chat.send_message(conversation.id, sender.id, "",
               gif_url: "http://example.com/reaction.gif"
             )

    assert {:error, :invalid_gif} =
             Chat.send_message(conversation.id, sender.id, "",
               gif_url: "https://example.com/not-an-image.jpg"
             )

    assert {:ok, message} =
             Chat.send_message(conversation.id, sender.id, "",
               gif_url: "https://cdn.example.com/reaction.gif"
             )

    assert message.body == ""
    assert message.json_metadata["format"] == "simple_markup_v1"

    assert message.attachments == [
             %{"type" => "gif", "url" => "https://cdn.example.com/reaction.gif"}
           ]
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

  test "forum topics are publicly readable without weakening private conversations" do
    host = Fixtures.user_fixture()
    player = Fixtures.user_fixture()
    outsider = Fixtures.user_fixture()

    assert {:ok, topic} =
             Chat.create_forum_topic(host.id, %{
               "title" => "After the verdict",
               "body" => "What changed your read?"
             })

    assert topic.kind == :forum
    assert [%{id: topic_id, creator: %{id: creator_id}}] = Chat.list_forum_topics()
    assert topic_id == topic.id
    assert creator_id == host.id

    assert {:ok, %{id: ^topic_id}} = Chat.get_forum_topic(topic.id)
    assert {:ok, [opening]} = Chat.list_forum_messages(topic.id)
    assert opening.body == "What changed your read?"

    assert {:error, :not_a_member} = Chat.list_messages(topic.id, outsider.id)
    assert {:error, :not_found} = Chat.get_conversation_for_user(topic.id, outsider.id)

    assert {:ok, private_conversation} =
             Chat.start_direct_conversation(host.id, player.id)

    assert {:ok, %{id: private_id}} = Chat.start_direct_conversation(host.id, player.id)
    assert private_id == private_conversation.id

    host_conversations = Chat.list_user_conversations(host.id)
    player_conversations = Chat.list_user_conversations(player.id)

    assert Enum.any?(host_conversations, &(&1.id == private_conversation.id))
    assert Enum.any?(player_conversations, &(&1.id == private_conversation.id))
    refute Enum.any?(host_conversations, &(&1.id == topic.id))

    assert {:ok, private_message} =
             Chat.send_message(private_conversation.id, host.id, "Members only")

    assert {:error, :not_found} = Chat.get_forum_topic(private_conversation.id)
    assert {:error, :not_found} = Chat.list_forum_messages(private_conversation.id)

    assert {:error, :not_found} =
             Chat.get_conversation_for_user(private_conversation.id, outsider.id)

    assert {:error, :not_found} =
             Chat.toggle_forum_reaction(private_message.id, outsider.id, "👍")
  end

  test "recent messages move a reused direct conversation to the top" do
    sender = Fixtures.user_fixture()
    first_recipient = Fixtures.user_fixture()
    second_recipient = Fixtures.user_fixture()

    assert {:ok, first} = Chat.start_direct_conversation(sender.id, first_recipient.id)
    assert {:ok, second} = Chat.start_direct_conversation(sender.id, second_recipient.id)

    assert MapSet.new(Chat.list_user_conversations(sender.id), & &1.id) ==
             MapSet.new([first.id, second.id])

    assert {:ok, _message} = Chat.send_message(first.id, sender.id, "Back to this one")
    assert [%{id: first_id} | _] = Chat.list_user_conversations(sender.id)
    assert first_id == first.id
  end

  test "forum replies and reactions join authenticated readers lazily" do
    host = Fixtures.user_fixture()
    reader = Fixtures.user_fixture()

    assert {:ok, topic} =
             Chat.create_forum_topic(host.id, %{
               title: "Night one review",
               body: "Post your strongest clue."
             })

    assert {:error, :not_found} = Chat.get_conversation_for_user(topic.id, reader.id)

    assert {:ok, reply} =
             Chat.reply_to_forum_topic(topic.id, reader.id, %{
               "body" => "The late vote switch mattered.",
               "gif_url" => "https://cdn.example.com/verdict.gif"
             })

    assert {:ok, _conversation} = Chat.get_conversation_for_user(topic.id, reader.id)
    assert {:ok, [opening, loaded_reply]} = Chat.list_forum_messages(topic.id)
    assert loaded_reply.id == reply.id

    assert loaded_reply.attachments == [
             %{"type" => "gif", "url" => "https://cdn.example.com/verdict.gif"}
           ]

    assert {:ok, reaction} = Chat.toggle_forum_reaction(opening.id, reader.id, "🤔")
    assert reaction.user_id == reader.id
    assert {:ok, :removed} = Chat.toggle_forum_reaction(opening.id, reader.id, "🤔")

    assert {:error, :unsupported_reaction} =
             Chat.toggle_forum_reaction(opening.id, reader.id, "🦠")
  end

  test "forum topics require a title and either text or a GIF" do
    host = Fixtures.user_fixture()

    assert {:error, :empty_title} =
             Chat.create_forum_topic(host.id, %{title: "  ", body: "Opening"})

    assert {:error, :empty_message} =
             Chat.create_forum_topic(host.id, %{title: "Valid title", body: "  "})

    assert {:ok, gif_topic} =
             Chat.create_forum_topic(host.id, %{
               title: "Reaction only",
               body: "",
               gif_url: "https://cdn.example.com/reaction.gif"
             })

    assert {:ok, [%{body: "", attachments: [attachment]}]} =
             Chat.list_forum_messages(gif_topic.id)

    assert attachment == %{
             "type" => "gif",
             "url" => "https://cdn.example.com/reaction.gif"
           }

    assert {:error, :title_too_long} =
             Chat.create_forum_topic(host.id, %{
               title: String.duplicate("a", 161),
               body: "Opening"
             })
  end
end
