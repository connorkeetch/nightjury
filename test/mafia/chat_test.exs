defmodule Mafia.ChatTest do
  use Mafia.DataCase, async: true

  alias Mafia.{Chat, Fixtures, Games}

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  test "username groups are listed for members while forums stay out of messages" do
    creator = Fixtures.user_fixture()
    member = Fixtures.user_fixture()

    assert {:ok, group} =
             Chat.create_group_conversation_by_usernames(creator.id, %{
               "title" => "  Weekend crew  ",
               "members" =>
                 "#{member.username}, #{String.upcase(member.username)} #{creator.username}"
             })

    assert group.title == "Weekend crew"
    assert Enum.any?(Chat.list_user_conversations(creator.id), &(&1.id == group.id))
    assert Enum.any?(Chat.list_user_conversations(member.id), &(&1.id == group.id))

    assert {:ok, forum} =
             Chat.create_forum_topic(creator.id, %{
               title: "Public post",
               body: "This belongs in the forum."
             })

    refute Enum.any?(Chat.list_user_conversations(creator.id), &(&1.id == forum.id))
  end

  test "standalone group lifecycle is role-gated and unavailable to game chats" do
    admin = Fixtures.user_fixture()
    member = Fixtures.user_fixture()

    assert {:ok, group} =
             Chat.create_group_conversation_by_usernames(admin.id, %{
               title: "Private crew",
               members: member.username
             })

    assert {:error, :not_admin} = Chat.delete_group_conversation(group.id, member.id)
    assert {:error, :admin_must_delete} = Chat.leave_group_conversation(group.id, admin.id)
    assert :ok = Chat.leave_group_conversation(group.id, member.id)
    assert {:error, :not_found} = Chat.get_conversation_for_user(group.id, member.id)
    assert {:ok, _archived} = Chat.delete_group_conversation(group.id, admin.id)
    refute Enum.any?(Chat.list_user_conversations(admin.id), &(&1.id == group.id))

    assert {:ok, game} = Games.create_game(admin.id)

    assert {:ok, game_chat} =
             Chat.create_group_conversation(admin.id, [member.id],
               kind: :game,
               game_id: game.id
             )

    assert {:error, :managed_conversation} =
             Chat.leave_group_conversation(game_chat.id, member.id)

    assert {:error, :managed_conversation} =
             Chat.delete_group_conversation(game_chat.id, admin.id)
  end

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

  test "replies must reference a message in the same conversation" do
    author = Fixtures.user_fixture()
    reader = Fixtures.user_fixture()

    assert {:ok, conversation} = Chat.create_group_conversation(author.id, [reader.id])
    assert {:ok, other_conversation} = Chat.create_group_conversation(author.id, [reader.id])
    assert {:ok, original} = Chat.send_message(conversation.id, author.id, "Original")
    assert {:ok, foreign} = Chat.send_message(other_conversation.id, author.id, "Private")

    assert {:ok, reply} =
             Chat.send_message(conversation.id, reader.id, "Reply",
               reply_to_message_id: original.id
             )

    assert reply.reply_to_message_id == original.id

    assert {:error, :reply_not_found} =
             Chat.send_message(conversation.id, reader.id, "Forged reply",
               reply_to_message_id: foreign.id
             )
  end

  test "image attachments validate type and size" do
    assert {:ok, attachment} = Chat.prepare_image_attachment(@png, "image.png")
    assert attachment["content_type"] == "image/png"
    assert attachment["size"] == byte_size(@png)
    assert {:error, :unsupported_image} = Chat.prepare_image_attachment("not an image", "x.txt")

    assert {:error, :invalid_image} =
             Chat.prepare_image_attachment(png_fixture(6_001, 1), "x.png")

    assert {:error, :image_too_large} =
             Chat.prepare_image_attachment(
               :binary.copy(<<0>>, Chat.image_max_bytes() + 1),
               "large.png"
             )
  end

  test "an image-only message stores metadata and stays private to members" do
    author = Fixtures.user_fixture()
    member = Fixtures.user_fixture()
    outsider = Fixtures.user_fixture()

    assert {:ok, conversation} = Chat.create_group_conversation(author.id, [member.id])
    assert {:ok, attachment} = Chat.prepare_image_attachment(@png, "evidence.png")

    assert {:ok, message} =
             Chat.send_message(conversation.id, author.id, "", attachments: [attachment])

    assert message.body == ""
    assert [metadata] = message.attachments
    assert metadata["content_type"] == "image/png"
    assert metadata["size"] == byte_size(@png)
    refute Map.has_key?(metadata, "data")

    assert {:ok, %{content_type: "image/png", data: @png}} =
             Chat.get_message_image(message.id, member.id)

    assert {:error, :not_found} = Chat.get_message_image(message.id, outsider.id)
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
             Chat.create_group_conversation(host.id, [player.id], title: "Private room")

    assert {:ok, private_message} =
             Chat.send_message(private_conversation.id, host.id, "Members only")

    assert {:error, :not_found} = Chat.get_forum_topic(private_conversation.id)
    assert {:error, :not_found} = Chat.list_forum_messages(private_conversation.id)

    assert {:error, :not_found} =
             Chat.get_conversation_for_user(private_conversation.id, outsider.id)

    assert {:error, :not_found} =
             Chat.toggle_forum_reaction(private_message.id, outsider.id, "👍")
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
             Chat.reply_to_forum_topic(topic.id, reader.id, "The late vote switch mattered.")

    assert {:ok, _conversation} = Chat.get_conversation_for_user(topic.id, reader.id)
    assert {:ok, [opening, loaded_reply]} = Chat.list_forum_messages(topic.id)
    assert loaded_reply.id == reply.id

    assert {:ok, reaction} = Chat.toggle_forum_reaction(opening.id, reader.id, "🤔")
    assert reaction.user_id == reader.id
    assert {:ok, :removed} = Chat.toggle_forum_reaction(opening.id, reader.id, "🤔")

    assert {:error, :unsupported_reaction} =
             Chat.toggle_forum_reaction(opening.id, reader.id, "🦠")
  end

  test "forum topics require a title and opening post" do
    host = Fixtures.user_fixture()

    assert {:error, :empty_title} =
             Chat.create_forum_topic(host.id, %{title: "  ", body: "Opening"})

    assert {:error, :empty_message} =
             Chat.create_forum_topic(host.id, %{title: "Valid title", body: "  "})

    assert {:error, :title_too_long} =
             Chat.create_forum_topic(host.id, %{
               title: String.duplicate("a", 161),
               body: "Opening"
             })
  end

  defp png_fixture(width, height) do
    header = <<width::32, height::32, 8, 6, 0, 0, 0>>

    <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>> <>
      png_chunk("IHDR", header) <>
      png_chunk("IDAT", <<>>) <>
      png_chunk("IEND", <<>>)
  end

  defp png_chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
  end
end
