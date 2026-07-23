defmodule Mafia.Chat do
  @moduledoc "Private game chat and public forum conversations."

  alias Mafia.{Accounts, GameRules, Games}
  alias Mafia.Chat.Resources.{Conversation, ConversationMember, Message, MessageReaction}
  alias Mafia.Repo

  require Ash.Query

  @allowed_reactions ["👍", "👎", "😂", "❤️", "🤔", "🎉"]
  @send_rate_window :timer.seconds(10)
  @send_rate_limit 10
  @reaction_rate_window :timer.seconds(10)
  @reaction_rate_limit 30
  @forum_topic_rate_window :timer.minutes(10)
  @forum_topic_rate_limit 5
  @forum_title_max_length 160
  @group_create_rate_window :timer.minutes(10)
  @group_create_rate_limit 5
  @group_title_max_length 120
  @group_member_limit 25
  @image_max_bytes 2_000_000
  @image_max_dimension 6_000
  @image_max_pixels 20_000_000
  @image_storage_quota_bytes 50_000_000
  @image_rate_window :timer.hours(1)
  @image_rate_limit 10

  def allowed_reactions, do: @allowed_reactions
  def image_max_bytes, do: @image_max_bytes

  def create_forum_topic(creator_id, attrs) when is_map(attrs) do
    title = attrs |> value(:title) |> to_string() |> String.trim()
    body = attrs |> value(:body) |> to_string() |> String.trim()

    with :ok <- Mafia.WriteGate.ensure_enabled(),
         %{} <- Accounts.get_user(creator_id),
         :ok <- validate_topic_title(title),
         :ok <- validate_body(body),
         :ok <- rate_limit_forum_topic(creator_id) do
      result =
        Repo.transaction(fn ->
          with {:ok, conversation} <-
                 Conversation
                 |> Ash.Changeset.for_create(:create, %{
                   kind: :forum,
                   creator_id: creator_id,
                   title: title
                 })
                 |> Ash.create(authorize?: false),
               :ok <- add_members(conversation.id, creator_id, []),
               {:ok, _message} <- create_message(conversation.id, creator_id, body) do
            conversation
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
        |> transaction_result()

      case result do
        {:ok, conversation} -> broadcast_and_return(conversation.id, result)
        error -> error
      end
    else
      nil -> {:error, :creator_not_found}
      {:error, _reason} = error -> error
    end
  end

  def create_forum_topic(_creator_id, _attrs), do: {:error, :invalid_topic}

  def list_forum_topics do
    Conversation
    |> Ash.Query.filter(kind == :forum and is_archived == false)
    |> Ash.Query.load(:creator)
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  def get_forum_topic(conversation_id) do
    case Ash.get(Conversation, conversation_id, authorize?: false) do
      {:ok, %Conversation{kind: :forum, is_archived: false} = conversation} ->
        Ash.load(conversation, :creator, authorize?: false)

      _ ->
        {:error, :not_found}
    end
  end

  def list_forum_messages(conversation_id) do
    with {:ok, _conversation} <- get_forum_topic(conversation_id) do
      read_messages(conversation_id)
    end
  end

  def join_forum_topic(conversation_id, user_id) do
    with :ok <- Mafia.WriteGate.ensure_enabled(),
         %{} <- Accounts.get_user(user_id),
         {:ok, _conversation} <- get_forum_topic(conversation_id) do
      case membership(conversation_id, user_id) do
        {:ok, member} ->
          {:ok, member}

        {:error, :not_a_member} ->
          ConversationMember
          |> Ash.Changeset.for_create(:create, %{
            conversation_id: conversation_id,
            user_id: user_id,
            role: :member
          })
          |> Ash.create(authorize?: false)
      end
    else
      nil -> {:error, :user_not_found}
      {:error, _reason} = error -> error
    end
  end

  def reply_to_forum_topic(conversation_id, user_id, body, opts \\ []) do
    with {:ok, _member} <- join_forum_topic(conversation_id, user_id) do
      send_message(conversation_id, user_id, body, opts)
    end
  end

  def toggle_forum_reaction(message_id, user_id, emoji) when emoji in @allowed_reactions do
    with {:ok, message} <- forum_message(message_id),
         {:ok, _member} <- join_forum_topic(message.conversation_id, user_id) do
      toggle_reaction(message_id, user_id, emoji)
    end
  end

  def toggle_forum_reaction(_message_id, _user_id, _emoji),
    do: {:error, :unsupported_reaction}

  def create_group_conversation(creator_id, member_ids, opts \\ []) do
    with :ok <- Mafia.WriteGate.ensure_enabled(),
         %{} <- Accounts.get_user(creator_id) do
      result =
        Repo.transaction(fn ->
          with {:ok, conversation} <-
                 Conversation
                 |> Ash.Changeset.for_create(:create, %{
                   kind: Keyword.get(opts, :kind, :group),
                   creator_id: creator_id,
                   title: Keyword.get(opts, :title),
                   game_id: Keyword.get(opts, :game_id),
                   metadata: Keyword.get(opts, :metadata, %{})
                 })
                 |> Ash.create(authorize?: false),
               :ok <-
                 add_members(
                   conversation.id,
                   creator_id,
                   member_ids,
                   Keyword.get(opts, :admin_ids, []),
                   Keyword.get(opts, :include_creator?, true)
                 ) do
            conversation
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
        |> transaction_result()

      if match?({:ok, _conversation}, result),
        do: broadcast_user_conversations([creator_id | List.wrap(member_ids)])

      result
    else
      _ -> {:error, :creator_not_found}
    end
  end

  def create_group_conversation_by_usernames(creator_id, attrs) when is_map(attrs) do
    title = attrs |> value(:title) |> to_string() |> String.trim()

    usernames =
      attrs
      |> value(:members)
      |> to_string()
      |> String.split(~r/[\s,]+/, trim: true)
      |> Enum.uniq_by(&String.downcase/1)

    with :ok <- Mafia.WriteGate.ensure_enabled(),
         %{} <- Accounts.get_user(creator_id),
         :ok <- validate_group_title(title),
         :ok <- validate_group_username_count(usernames),
         {:ok, member_ids} <- resolve_group_members(usernames, creator_id),
         :ok <- validate_group_members(member_ids),
         :ok <- rate_limit_group_create(creator_id) do
      create_group_conversation(creator_id, member_ids, title: title)
    else
      nil -> {:error, :creator_not_found}
      {:error, _reason} = error -> error
    end
  end

  def create_group_conversation_by_usernames(_creator_id, _attrs),
    do: {:error, :invalid_group}

  def list_user_conversations(user_id) do
    ConversationMember
    |> Ash.Query.filter(user_id == ^user_id and is_nil(hidden_at))
    |> Ash.Query.load(:conversation)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.conversation)
    |> Enum.reject(&(&1.is_archived or &1.kind == :forum))
    |> Enum.filter(&conversation_readable?(&1, user_id))
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  @doc "Active conversations attached to a game, including faction and side chats."
  def list_game_conversations(game_id) do
    Conversation
    |> Ash.Query.filter(game_id == ^game_id and is_archived == false)
    |> Ash.Query.sort(created_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  @doc "Reconciles members while preserving the moderator performing the sync."
  def sync_conversation_members(conversation_id, actor_id, member_ids, opts \\ []) do
    member_ids = member_ids |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()
    preserve_actor? = Keyword.get(opts, :preserve_actor?, true)

    with :ok <- Mafia.WriteGate.ensure_enabled(),
         {:ok, conversation} <- Ash.get(Conversation, conversation_id, authorize?: false),
         :ok <- authorize_membership_sync(conversation, actor_id) do
      result =
        Repo.transaction(fn ->
          current =
            ConversationMember
            |> Ash.Query.filter(conversation_id == ^conversation_id)
            |> Ash.read!(authorize?: false)

          current_ids = MapSet.new(current, & &1.user_id)

          with :ok <- add_missing_members(conversation_id, member_ids, current_ids),
               :ok <- remove_extra_members(current, member_ids, actor_id, preserve_actor?) do
            :ok
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, :ok} ->
          broadcast(conversation_id)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def get_conversation_for_user(conversation_id, user_id) do
    with {:ok, _member} <- membership(conversation_id, user_id),
         {:ok, conversation} <- Ash.get(Conversation, conversation_id, authorize?: false),
         :ok <- verify_can_read(conversation, user_id),
         {:ok, loaded} <- Ash.load(conversation, [members: [:user]], authorize?: false) do
      {:ok, loaded}
    else
      _ -> {:error, :not_found}
    end
  end

  def list_messages(conversation_id, user_id) do
    with {:ok, _member} <- membership(conversation_id, user_id),
         {:ok, conversation} <- Ash.get(Conversation, conversation_id, authorize?: false),
         :ok <- verify_can_read(conversation, user_id) do
      read_messages(conversation_id)
    end
  end

  def send_message(conversation_id, user_id, body, opts \\ []) do
    system? = Keyword.get(opts, :system, false)
    reply_to_message_id = normalize_reply_id(Keyword.get(opts, :reply_to_message_id))
    attachments = Keyword.get(opts, :attachments, [])
    body = body |> to_string() |> String.trim()

    with :ok <- Mafia.WriteGate.ensure_enabled(),
         {:ok, member} <- membership(conversation_id, user_id),
         :ok <- maybe_rate_limit_send(system?, conversation_id, user_id),
         {:ok, conversation} <- Ash.get(Conversation, conversation_id, authorize?: false),
         :ok <- validate_attachments(attachments),
         :ok <- maybe_rate_limit_image(attachments, user_id),
         :ok <- verify_can_send(member, conversation, body, attachments, system?, user_id),
         :ok <- validate_reply(conversation_id, reply_to_message_id),
         {:ok, message} <-
           create_message(
             conversation_id,
             user_id,
             body,
             %{
               json_metadata: if(system?, do: %{"system" => true}, else: %{}),
               reply_to_message_id: reply_to_message_id,
               attachments: attachments
             }
           ) do
      broadcast(conversation_id)
      {:ok, message}
    end
  end

  def prepare_image_attachment(data, name) when is_binary(data) do
    with :ok <- validate_image_size(data),
         {:ok, content_type} <- validate_image(data) do
      {:ok,
       %{
         "id" => Ecto.UUID.generate(),
         "name" => safe_image_name(name),
         "content_type" => content_type,
         "size" => byte_size(data),
         "data" => data
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  def prepare_image_attachment(_data, _name), do: {:error, :unsupported_image}

  def get_message_image(message_id, user_id) do
    with {:ok, %Message{deleted_at: nil} = message} <-
           Ash.get(Message, message_id, authorize?: false),
         {:ok, _member} <- membership(message.conversation_id, user_id),
         {:ok, conversation} <-
           Ash.get(Conversation, message.conversation_id, authorize?: false),
         :ok <- verify_can_read(conversation, user_id),
         %{"id" => image_id} <- List.first(message.attachments || []),
         {:ok, %{rows: [[content_type, data]]}} <-
           Repo.query(
             "SELECT content_type, data FROM message_images WHERE id = $1::uuid AND message_id = $2::uuid",
             [image_id, message.id]
           ) do
      {:ok, %{content_type: content_type, data: data}}
    else
      _ -> {:error, :not_found}
    end
  end

  def set_conversation_read_only(conversation_id, actor_id, read_only?) do
    with :ok <- Mafia.WriteGate.ensure_enabled(),
         {:ok, _admin} <- admin_membership(conversation_id, actor_id),
         {:ok, conversation} <- Ash.get(Conversation, conversation_id, authorize?: false),
         {:ok, updated} <-
           conversation
           |> Ash.Changeset.for_update(:update, %{is_read_only: read_only?})
           |> Ash.update(authorize?: false) do
      broadcast(conversation_id)
      {:ok, updated}
    end
  end

  def shadow_mute_member(conversation_id, actor_id, user_id, shadow_muted?) do
    with :ok <- Mafia.WriteGate.ensure_enabled(),
         {:ok, _admin} <- admin_membership(conversation_id, actor_id),
         {:ok, member} <- membership(conversation_id, user_id),
         {:ok, updated} <-
           member
           |> Ash.Changeset.for_update(:update, %{shadow_muted: shadow_muted?})
           |> Ash.update(authorize?: false) do
      broadcast(conversation_id)
      {:ok, updated}
    end
  end

  def archive_conversation(conversation_id, actor_id) do
    with :ok <- Mafia.WriteGate.ensure_enabled(),
         {:ok, conversation} <- Ash.get(Conversation, conversation_id, authorize?: false),
         :ok <- authorize_membership_sync(conversation, actor_id) do
      result =
        Repo.transaction(fn ->
          with {:ok, updated} <-
                 conversation
                 |> Ash.Changeset.for_update(:update, %{is_archived: true})
                 |> Ash.update(authorize?: false),
               {:ok, _result} <-
                 Repo.query(
                   """
                   DELETE FROM message_images
                   WHERE message_id IN (
                     SELECT id FROM messages WHERE conversation_id = $1::uuid
                   )
                   """,
                   [conversation_id]
                 ) do
            updated
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
        |> transaction_result()

      case result do
        {:ok, updated} ->
          broadcast(conversation_id)
          conversation_id |> conversation_user_ids() |> broadcast_user_conversations()
          {:ok, updated}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def delete_group_conversation(conversation_id, actor_id) do
    with {:ok, _conversation} <- standalone_group_conversation(conversation_id) do
      archive_conversation(conversation_id, actor_id)
    end
  end

  def leave_group_conversation(conversation_id, user_id) do
    with :ok <- Mafia.WriteGate.ensure_enabled(),
         {:ok, _conversation} <- standalone_group_conversation(conversation_id),
         {:ok, member} <- membership(conversation_id, user_id),
         :ok <- ensure_member_can_leave(member),
         :ok <- destroy_member(member) do
      broadcast(conversation_id)
      broadcast_user_conversations([user_id])
      :ok
    end
  end

  def toggle_reaction(message_id, user_id, emoji) when emoji in @allowed_reactions do
    with :ok <- Mafia.WriteGate.ensure_enabled(),
         {:ok, message} <- Ash.get(Message, message_id, authorize?: false),
         {:ok, member} <- membership(message.conversation_id, user_id),
         {:ok, conversation} <-
           Ash.get(Conversation, message.conversation_id, authorize?: false),
         :ok <- verify_can_react(member, conversation, user_id),
         :ok <- rate_limit_reaction(message.conversation_id, user_id) do
      case find_reaction(message_id, user_id, emoji) do
        {:ok, %MessageReaction{} = reaction} ->
          case Ash.destroy(reaction, authorize?: false) do
            :ok -> broadcast_and_return(message.conversation_id, {:ok, :removed})
            {:ok, _} -> broadcast_and_return(message.conversation_id, {:ok, :removed})
            {:error, _} = error -> error
          end

        {:error, :not_found} ->
          result =
            MessageReaction
            |> Ash.Changeset.for_create(:create, %{
              message_id: message_id,
              user_id: user_id,
              emoji: emoji
            })
            |> Ash.create(authorize?: false)

          case result do
            {:ok, reaction} ->
              broadcast_and_return(message.conversation_id, {:ok, reaction})

            {:error, _} = error ->
              error
          end
      end
    end
  end

  def toggle_reaction(_, _, _), do: {:error, :unsupported_reaction}

  def subscribe(conversation_id) do
    Phoenix.PubSub.subscribe(Mafia.PubSub, "conversation:#{conversation_id}")
  end

  def subscribe_user_conversations(user_id) do
    Phoenix.PubSub.subscribe(Mafia.PubSub, "user_conversations:#{user_id}")
  end

  @doc "Publishes a refresh after a caller-owned database transaction commits."
  def refresh_conversation(conversation_id) do
    broadcast(conversation_id)
    :ok
  end

  defp add_members(conversation_id, creator_id, member_ids),
    do: add_members(conversation_id, creator_id, member_ids, [], true)

  defp add_members(conversation_id, creator_id, member_ids, admin_ids, include_creator?) do
    admin_ids = MapSet.new([creator_id | admin_ids])

    if(include_creator?, do: [creator_id | member_ids], else: member_ids)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn user_id, :ok ->
      attrs = %{
        conversation_id: conversation_id,
        user_id: user_id,
        role: if(MapSet.member?(admin_ids, user_id), do: :admin, else: :member)
      }

      case ConversationMember
           |> Ash.Changeset.for_create(:create, attrs)
           |> Ash.create(authorize?: false) do
        {:ok, _member} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp add_missing_members(conversation_id, desired_ids, current_ids) do
    desired_ids
    |> MapSet.difference(current_ids)
    |> Enum.reduce_while(:ok, fn user_id, :ok ->
      result =
        ConversationMember
        |> Ash.Changeset.for_create(:create, %{
          conversation_id: conversation_id,
          user_id: user_id,
          role: :member
        })
        |> Ash.create(authorize?: false)

      case result do
        {:ok, _member} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp remove_extra_members(current, desired_ids, actor_id, preserve_actor?) do
    current
    |> Enum.reject(fn member ->
      (preserve_actor? and member.user_id == actor_id) or
        MapSet.member?(desired_ids, member.user_id)
    end)
    |> Enum.reduce_while(:ok, fn member, :ok ->
      case Ash.destroy(member, authorize?: false) do
        :ok -> {:cont, :ok}
        {:ok, _member} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp authorize_membership_sync(
         %Conversation{id: conversation_id, game_id: game_id, metadata: metadata},
         actor_id
       )
       when not is_nil(game_id) do
    case Games.get_game(game_id) do
      {:ok, %{host_id: ^actor_id}} ->
        :ok

      _ ->
        if Map.get(metadata || %{}, "moderator_id") == actor_id,
          do: :ok,
          else: membership_admin_result(conversation_id, actor_id)
    end
  end

  defp authorize_membership_sync(%Conversation{id: conversation_id}, actor_id),
    do: membership_admin_result(conversation_id, actor_id)

  defp membership_admin_result(conversation_id, actor_id) do
    case admin_membership(conversation_id, actor_id) do
      {:ok, _admin} -> :ok
      {:error, _reason} -> {:error, :not_admin}
    end
  end

  defp membership(conversation_id, user_id) do
    ConversationMember
    |> Ash.Query.filter(conversation_id == ^conversation_id and user_id == ^user_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ConversationMember{} = member} -> {:ok, member}
      _ -> {:error, :not_a_member}
    end
  end

  defp admin_membership(conversation_id, user_id) do
    case membership(conversation_id, user_id) do
      {:ok, %ConversationMember{role: :admin} = member} -> {:ok, member}
      _ -> {:error, :not_admin}
    end
  end

  defp find_reaction(message_id, user_id, emoji) do
    MessageReaction
    |> Ash.Query.filter(message_id == ^message_id and user_id == ^user_id and emoji == ^emoji)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %MessageReaction{} = reaction} -> {:ok, reaction}
      _ -> {:error, :not_found}
    end
  end

  defp forum_message(message_id) do
    case Ash.get(Message, message_id, authorize?: false) do
      {:ok, %Message{} = message} ->
        case get_forum_topic(message.conversation_id) do
          {:ok, _conversation} -> {:ok, message}
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp read_messages(conversation_id) do
    Message
    |> Ash.Query.filter(conversation_id == ^conversation_id and is_nil(deleted_at))
    |> Ash.Query.sort(created_at: :asc)
    |> Ash.Query.load([:user, reactions: [:user]])
    |> Ash.read(authorize?: false)
  end

  defp conversation_user_ids(conversation_id) do
    ConversationMember
    |> Ash.Query.filter(conversation_id == ^conversation_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.user_id)
  end

  defp create_message(conversation_id, user_id, body, attrs \\ %{}) do
    attachments = Map.get(attrs, :attachments, [])

    message_attrs = %{
      conversation_id: conversation_id,
      user_id: user_id,
      body: body,
      json_metadata: Map.get(attrs, :json_metadata, %{}),
      reply_to_message_id: Map.get(attrs, :reply_to_message_id),
      attachments: Enum.map(attachments, &Map.drop(&1, ["data"]))
    }

    if attachments == [] do
      Message
      |> Ash.Changeset.for_create(:create, message_attrs)
      |> Ash.create(authorize?: false)
    else
      Repo.transaction(fn ->
        with {:ok, message} <-
               Message
               |> Ash.Changeset.for_create(:create, message_attrs)
               |> Ash.create(authorize?: false),
             :ok <- store_message_images(message.id, user_id, attachments) do
          message
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> transaction_result()
    end
  end

  defp verify_can_send(
         _member,
         %{is_archived: true},
         _body,
         _attachments,
         _system?,
         _user_id
       ),
       do: {:error, :archived}

  defp verify_can_send(
         %{role: :spectator},
         _conversation,
         _body,
         _attachments,
         _system?,
         _user_id
       ),
       do: {:error, :read_only}

  defp verify_can_send(
         %{shadow_muted: true},
         _conversation,
         _body,
         _attachments,
         _system?,
         _user_id
       ),
       do: {:error, :muted}

  defp verify_can_send(%{role: :admin}, _conversation, body, _attachments, true, _user_id),
    do: validate_body(body)

  defp verify_can_send(
         _member,
         %{is_read_only: true},
         _body,
         _attachments,
         _system?,
         _user_id
       ),
       do: {:error, :read_only}

  defp verify_can_send(_member, conversation, body, attachments, _system?, user_id) do
    with :ok <- verify_game_capability(conversation, user_id, "post_public") do
      validate_message_content(body, attachments)
    end
  end

  defp validate_body(""), do: {:error, :empty_message}
  defp validate_body(body) when byte_size(body) > 10_000, do: {:error, :message_too_long}
  defp validate_body(_), do: :ok

  defp validate_message_content("", []), do: {:error, :empty_message}

  defp validate_message_content(body, _attachments) when byte_size(body) > 10_000,
    do: {:error, :message_too_long}

  defp validate_message_content(_body, _attachments), do: :ok

  defp validate_reply(_conversation_id, nil), do: :ok

  defp validate_reply(conversation_id, reply_to_message_id)
       when is_binary(reply_to_message_id) do
    case Ash.get(Message, reply_to_message_id, authorize?: false) do
      {:ok, %Message{conversation_id: ^conversation_id, deleted_at: nil}} -> :ok
      _ -> {:error, :reply_not_found}
    end
  end

  defp validate_reply(_conversation_id, _reply_to_message_id),
    do: {:error, :reply_not_found}

  defp normalize_reply_id(reply_to_message_id) when reply_to_message_id in [nil, ""], do: nil
  defp normalize_reply_id(reply_to_message_id), do: reply_to_message_id

  defp validate_attachments(attachments) when is_list(attachments) and length(attachments) <= 1 do
    Enum.reduce_while(attachments, :ok, fn attachment, :ok ->
      case validate_attachment(attachment) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_attachments(_attachments), do: {:error, :invalid_image}

  defp validate_attachment(
         %{
           "id" => id,
           "content_type" => content_type,
           "size" => size,
           "data" => data
         } = attachment
       )
       when is_binary(id) and is_binary(content_type) and is_integer(size) and
              is_binary(data) do
    with {:ok, _id} <- Ecto.UUID.cast(id),
         true <- size == byte_size(data),
         :ok <- validate_image_size(data),
         {:ok, ^content_type} <- validate_image(data),
         true <- is_binary(Map.get(attachment, "name")) do
      :ok
    else
      _ -> {:error, :invalid_image}
    end
  end

  defp validate_attachment(_attachment), do: {:error, :invalid_image}

  defp validate_image_size(data) when byte_size(data) > @image_max_bytes,
    do: {:error, :image_too_large}

  defp validate_image_size(<<>>), do: {:error, :unsupported_image}
  defp validate_image_size(_data), do: :ok

  defp validate_image(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>> = data) do
    if valid_png?(data), do: {:ok, "image/png"}, else: {:error, :invalid_image}
  end

  defp validate_image(<<0xFF, 0xD8, _rest::binary>> = data) do
    if valid_jpeg?(data), do: {:ok, "image/jpeg"}, else: {:error, :invalid_image}
  end

  defp validate_image(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>> = data) do
    if valid_webp?(data), do: {:ok, "image/webp"}, else: {:error, :invalid_image}
  end

  defp validate_image(_data), do: {:error, :unsupported_image}

  defp valid_png?(
         <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR",
           header::binary-size(13), crc::32, rest::binary>>
       ) do
    <<width::32, height::32, _header_data::binary>> = header

    :erlang.crc32("IHDR" <> header) == crc and
      valid_image_dimensions?(width, height) and valid_png_chunks?(rest, false)
  end

  defp valid_png?(_data), do: false

  defp valid_png_chunks?(
         <<length::32, type::binary-size(4), data::binary-size(length), crc::32, rest::binary>>,
         seen_idat?
       ) do
    if :erlang.crc32(type <> data) == crc do
      case type do
        "IEND" -> length == 0 and seen_idat? and rest == <<>>
        "IHDR" -> false
        "IDAT" -> valid_png_chunks?(rest, true)
        _other -> valid_png_chunks?(rest, seen_idat?)
      end
    else
      false
    end
  end

  defp valid_png_chunks?(_data, _seen_idat?), do: false

  @jpeg_sof_markers [
    0xC0,
    0xC1,
    0xC2,
    0xC3,
    0xC5,
    0xC6,
    0xC7,
    0xC9,
    0xCA,
    0xCB,
    0xCD,
    0xCE,
    0xCF
  ]

  defp valid_jpeg?(<<0xFF, 0xD8, rest::binary>>), do: jpeg_segments_valid?(rest, nil)
  defp valid_jpeg?(_data), do: false

  defp jpeg_segments_valid?(<<0xFF, 0xFF, rest::binary>>, dimensions),
    do: jpeg_segments_valid?(<<0xFF, rest::binary>>, dimensions)

  defp jpeg_segments_valid?(<<0xFF, marker, rest::binary>>, dimensions)
       when marker in 0xD0..0xD7 or marker == 0x01,
       do: jpeg_segments_valid?(rest, dimensions)

  defp jpeg_segments_valid?(
         <<0xFF, 0xDA, length::16, rest::binary>>,
         dimensions
       )
       when length >= 2 do
    header_size = length - 2

    case rest do
      <<_scan_header::binary-size(^header_size), scan::binary>> ->
        not is_nil(dimensions) and byte_size(scan) > 2 and
          String.ends_with?(scan, <<0xFF, 0xD9>>)

      _ ->
        false
    end
  end

  defp jpeg_segments_valid?(<<0xFF, marker, length::16, rest::binary>>, dimensions)
       when length >= 2 and marker not in [0xD8, 0xD9] do
    payload_size = length - 2

    case rest do
      <<payload::binary-size(^payload_size), tail::binary>> ->
        case jpeg_dimensions(marker, payload, dimensions) do
          :invalid -> false
          next_dimensions -> jpeg_segments_valid?(tail, next_dimensions)
        end

      _ ->
        false
    end
  end

  defp jpeg_segments_valid?(_data, _dimensions), do: false

  defp jpeg_dimensions(
         marker,
         <<_precision, height::16, width::16, _rest::binary>>,
         _dimensions
       )
       when marker in @jpeg_sof_markers do
    if valid_image_dimensions?(width, height), do: {width, height}, else: :invalid
  end

  defp jpeg_dimensions(marker, _payload, _dimensions) when marker in @jpeg_sof_markers,
    do: :invalid

  defp jpeg_dimensions(_marker, _payload, dimensions), do: dimensions

  defp valid_webp?(<<"RIFF", declared_size::little-32, "WEBP", chunks::binary>>)
       when declared_size == byte_size(chunks) + 4 do
    valid_webp_chunks?(chunks, nil)
  end

  defp valid_webp?(_data), do: false

  defp valid_webp_chunks?(<<>>, {width, height}),
    do: valid_image_dimensions?(width, height)

  defp valid_webp_chunks?(
         <<type::binary-size(4), size::little-32, rest::binary>>,
         dimensions
       ) do
    padding = rem(size, 2)

    case rest do
      <<payload::binary-size(^size), _padding::binary-size(^padding), tail::binary>> ->
        case webp_dimensions(type, payload, dimensions) do
          :invalid -> false
          next_dimensions -> valid_webp_chunks?(tail, next_dimensions)
        end

      _ ->
        false
    end
  end

  defp valid_webp_chunks?(_data, _dimensions), do: false

  defp webp_dimensions(
         "VP8X",
         <<_flags, _reserved::binary-size(3), width_minus_one::little-unsigned-integer-size(24),
           height_minus_one::little-unsigned-integer-size(24), _rest::binary>>,
         _dimensions
       ),
       do: {width_minus_one + 1, height_minus_one + 1}

  defp webp_dimensions(
         "VP8L",
         <<0x2F, byte0, byte1, byte2, byte3, _rest::binary>>,
         _dimensions
       ) do
    width = 1 + byte0 + Bitwise.band(byte1, 0x3F) * 256
    height = 1 + div(byte1, 64) + byte2 * 4 + Bitwise.band(byte3, 0x0F) * 1024
    {width, height}
  end

  defp webp_dimensions(
         "VP8 ",
         <<_frame_tag::binary-size(3), 0x9D, 0x01, 0x2A, width_raw::little-16,
           height_raw::little-16, _rest::binary>>,
         _dimensions
       ),
       do: {Bitwise.band(width_raw, 0x3FFF), Bitwise.band(height_raw, 0x3FFF)}

  defp webp_dimensions(type, _payload, _dimensions) when type in ["VP8X", "VP8L", "VP8 "],
    do: :invalid

  defp webp_dimensions(_type, _payload, dimensions), do: dimensions

  defp valid_image_dimensions?(width, height) do
    width > 0 and height > 0 and width <= @image_max_dimension and
      height <= @image_max_dimension and width * height <= @image_max_pixels
  end

  defp safe_image_name(name) do
    name
    |> to_string()
    |> Path.basename()
    |> String.slice(0, 120)
  end

  defp store_message_images(message_id, user_id, attachments) do
    # ponytail: database blobs keep this durable without new infrastructure;
    # move media to private object storage if attachment volume becomes material.
    new_bytes = Enum.sum(Enum.map(attachments, & &1["size"]))

    with {:ok, _result} <-
           Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [user_id]),
         {:ok, %{rows: [[used_bytes]]}} <-
           Repo.query(
             """
             SELECT COALESCE(SUM(octet_length(image.data)), 0)
             FROM message_images image
             JOIN messages message ON message.id = image.message_id
             WHERE message.user_id = $1::uuid
             """,
             [user_id]
           ),
         true <- used_bytes + new_bytes <= @image_storage_quota_bytes do
      insert_message_images(message_id, attachments)
    else
      false -> {:error, :image_quota_exceeded}
      {:error, _reason} = error -> error
    end
  end

  defp insert_message_images(message_id, attachments) do
    Enum.reduce_while(attachments, :ok, fn attachment, :ok ->
      case Repo.query(
             """
             INSERT INTO message_images (id, message_id, content_type, data, created_at)
             VALUES ($1::uuid, $2::uuid, $3, $4, now())
             """,
             [
               attachment["id"],
               message_id,
               attachment["content_type"],
               attachment["data"]
             ]
           ) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_topic_title(""), do: {:error, :empty_title}

  defp validate_topic_title(title) do
    if String.length(title) > @forum_title_max_length,
      do: {:error, :title_too_long},
      else: :ok
  end

  defp validate_group_title(""), do: {:error, :empty_title}

  defp validate_group_title(title) do
    if String.length(title) > @group_title_max_length,
      do: {:error, :title_too_long},
      else: :ok
  end

  defp validate_group_username_count(usernames) do
    if length(usernames) > @group_member_limit + 1,
      do: {:error, :too_many_members},
      else: :ok
  end

  defp validate_group_members([]), do: {:error, :members_required}

  defp validate_group_members(member_ids) do
    if length(member_ids) > @group_member_limit,
      do: {:error, :too_many_members},
      else: :ok
  end

  defp resolve_group_members(usernames, creator_id) do
    usernames
    |> Enum.reduce_while({:ok, []}, fn username, {:ok, ids} ->
      case Accounts.get_user_by_username(username) do
        nil -> {:halt, {:error, {:user_not_found, username}}}
        %{id: ^creator_id} -> {:cont, {:ok, ids}}
        user -> {:cont, {:ok, [user.id | ids]}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.uniq(ids)}
      error -> error
    end
  end

  defp standalone_group_conversation(conversation_id) do
    case Ash.get(Conversation, conversation_id, authorize?: false) do
      {:ok, %Conversation{kind: :group, game_id: nil} = conversation} ->
        if Map.get(conversation.metadata || %{}, "mafia_game_id"),
          do: {:error, :managed_conversation},
          else: {:ok, conversation}

      {:ok, %Conversation{}} ->
        {:error, :managed_conversation}

      _ ->
        {:error, :not_found}
    end
  end

  defp ensure_member_can_leave(%ConversationMember{role: :admin}),
    do: {:error, :admin_must_delete}

  defp ensure_member_can_leave(%ConversationMember{}), do: :ok

  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) || ""

  defp destroy_member(member) do
    case Ash.destroy(member, authorize?: false) do
      :ok -> :ok
      {:ok, _member} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp maybe_rate_limit_send(true, _conversation_id, _user_id), do: :ok

  defp maybe_rate_limit_send(false, conversation_id, user_id) do
    rate_limit(
      "chat:send:#{user_id}:#{conversation_id}",
      @send_rate_window,
      @send_rate_limit
    )
  end

  defp maybe_rate_limit_image([], _user_id), do: :ok

  defp maybe_rate_limit_image(_attachments, user_id) do
    rate_limit("chat:image:#{user_id}", @image_rate_window, @image_rate_limit)
  end

  defp rate_limit_reaction(conversation_id, user_id) do
    rate_limit(
      "chat:reaction:#{user_id}:#{conversation_id}",
      @reaction_rate_window,
      @reaction_rate_limit
    )
  end

  defp rate_limit_forum_topic(user_id) do
    rate_limit(
      "chat:forum-topic:#{user_id}",
      @forum_topic_rate_window,
      @forum_topic_rate_limit
    )
  end

  defp rate_limit_group_create(user_id) do
    rate_limit(
      "chat:group-create:#{user_id}",
      @group_create_rate_window,
      @group_create_rate_limit
    )
  end

  defp rate_limit(key, window, limit) do
    if rate_limits_enabled?() do
      case Mafia.RateLimit.hit(key, window, limit) do
        {:allow, _count} -> :ok
        {:deny, _retry_after_ms} -> {:error, :rate_limited}
      end
    else
      :ok
    end
  end

  defp rate_limits_enabled? do
    :mafia
    |> Application.get_env(:rate_limit, [])
    |> Keyword.get(:enabled, true)
  end

  defp verify_can_react(_member, %{is_archived: true}, _user_id),
    do: {:error, :archived}

  defp verify_can_react(%{role: :spectator}, _conversation, _user_id),
    do: {:error, :read_only}

  defp verify_can_react(member, conversation, user_id) do
    if is_nil(conversation.game_id) and member.shadow_muted do
      {:error, :muted}
    else
      verify_game_capability(conversation, user_id, "react")
    end
  end

  defp verify_can_read(%Conversation{is_archived: true}, _user_id), do: {:error, :archived}

  defp verify_can_read(conversation, user_id) do
    if private_game_channel?(conversation) do
      verify_game_capability(conversation, user_id, "private_chat")
    else
      :ok
    end
  end

  defp conversation_readable?(conversation, user_id),
    do: verify_can_read(conversation, user_id) == :ok

  defp verify_game_capability(%Conversation{game_id: nil}, _user_id, _capability), do: :ok

  defp verify_game_capability(%Conversation{} = conversation, user_id, capability) do
    with {:ok, game} <- Games.get_game(conversation.game_id) do
      cond do
        game.host_id == user_id ->
          :ok

        private_game_channel?(conversation) and
            not private_game_channel_open?(conversation, game) ->
          {:error, :read_only}

        true ->
          case Games.fetch_player(game.id, user_id) do
            {:ok, player} ->
              required =
                cond do
                  private_game_channel?(conversation) and capability == "post_public" ->
                    ["private_chat"]

                  private_game_channel?(conversation) ->
                    ["private_chat", capability]

                  true ->
                    [capability]
                end

              if Enum.all?(required, &GameRules.capability?(game.ruleset, player, &1)),
                do: :ok,
                else: {:error, :capability_not_allowed}

            _ ->
              {:error, :read_only}
          end
      end
    else
      _ -> {:error, :read_only}
    end
  end

  defp private_game_channel?(%Conversation{metadata: metadata}) do
    Map.get(metadata || %{}, "channel") in ["faction", "side_chat"]
  end

  defp private_game_channel_open?(conversation, game) do
    metadata = conversation.metadata || %{}

    phase_matches? =
      Map.get(metadata, "channel") != "side_chat" or
        Map.get(metadata, "phase_number") == game.phase_number

    game.status in [:day, :night] and phase_matches? and
      GameRules.private_chat_allowed?(game.ruleset, game.status)
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp broadcast_and_return(conversation_id, result) do
    broadcast(conversation_id)
    result
  end

  defp broadcast(conversation_id) do
    Phoenix.PubSub.broadcast(Mafia.PubSub, "conversation:#{conversation_id}", :messages_changed)
  end

  defp broadcast_user_conversations(user_ids) do
    user_ids
    |> Enum.uniq()
    |> Enum.each(
      &Phoenix.PubSub.broadcast(
        Mafia.PubSub,
        "user_conversations:#{&1}",
        :conversations_changed
      )
    )
  end
end
