defmodule Mafia.Chat do
  @moduledoc "Private game chat and public forum conversations."

  alias Mafia.{Accounts, GameRules, Games}
  alias Mafia.Chat.Resources.{Conversation, ConversationMember, Message, MessageReaction}
  alias Mafia.Repo

  require Ash.Query

  @allowed_reactions ["👍", "👎", "😂", "❤️", "🤔", "🎉"]
  @send_rate_window :timer.seconds(10)
  @send_rate_limit 10
  @global_send_rate_limit 20
  @reaction_rate_window :timer.seconds(10)
  @reaction_rate_limit 30
  @forum_topic_rate_window :timer.minutes(10)
  @forum_topic_rate_limit 5
  @direct_start_rate_window :timer.minutes(10)
  @direct_start_rate_limit 5
  @forum_title_max_length 160
  @message_format "simple_markup_v1"
  @gif_url_max_length 2_048

  def allowed_reactions, do: @allowed_reactions

  def create_forum_topic(creator_id, attrs) when is_map(attrs) do
    title = attrs |> value(:title) |> to_string() |> String.trim()
    body = attrs |> value(:body) |> to_string() |> String.trim()
    gif_url = attrs |> value(:gif_url) |> to_string() |> String.trim()

    with :ok <- Mafia.WriteGate.ensure_enabled(),
         %{} <- Accounts.get_user(creator_id),
         :ok <- validate_topic_title(title),
         {:ok, attachments} <- gif_attachments(gif_url),
         :ok <- validate_message(body, attachments),
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
               {:ok, _message} <-
                 create_message(
                   conversation.id,
                   creator_id,
                   body,
                   %{"format" => @message_format},
                   attachments
                 ) do
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

  def reply_to_forum_topic(conversation_id, user_id, attrs) when is_map(attrs) do
    with {:ok, _member} <- join_forum_topic(conversation_id, user_id) do
      send_message(conversation_id, user_id, value(attrs, :body), gif_url: value(attrs, :gif_url))
    end
  end

  def reply_to_forum_topic(conversation_id, user_id, body) do
    with {:ok, _member} <- join_forum_topic(conversation_id, user_id) do
      send_message(conversation_id, user_id, body)
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

  def start_direct_conversation(creator_id, recipient_id)
      when is_binary(creator_id) and is_binary(recipient_id) do
    with :ok <- Mafia.WriteGate.ensure_enabled(),
         %{} = creator <- Accounts.get_user(creator_id),
         %{} = recipient <- Accounts.get_user(recipient_id),
         false <- creator_id == recipient_id do
      case direct_conversation_for(creator_id, recipient_id) do
        %Conversation{} = conversation ->
          {:ok, conversation}

        nil ->
          with :ok <- rate_limit_direct_start(creator_id) do
            # ponytail: best-effort pair reuse; add a canonical pair key and unique index if concurrent duplicates occur.
            create_group_conversation(creator_id, [recipient_id],
              kind: :direct,
              title: "#{creator.username} & #{recipient.username}"
            )
          end
      end
    else
      nil -> {:error, :user_not_found}
      true -> {:error, :self_conversation}
      {:error, _reason} = error -> error
    end
  end

  def start_direct_conversation(_creator_id, _recipient_id), do: {:error, :user_not_found}

  def create_group_conversation(creator_id, member_ids, opts \\ []) do
    with :ok <- Mafia.WriteGate.ensure_enabled(),
         %{} <- Accounts.get_user(creator_id) do
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
    else
      _ -> {:error, :creator_not_found}
    end
  end

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
    body = body |> to_string() |> String.trim()

    with :ok <- Mafia.WriteGate.ensure_enabled(),
         {:ok, attachments} <- gif_attachments(Keyword.get(opts, :gif_url)),
         {:ok, member} <- membership(conversation_id, user_id),
         :ok <- maybe_rate_limit_send(system?, conversation_id, user_id),
         {:ok, conversation} <- Ash.get(Conversation, conversation_id, authorize?: false),
         :ok <- verify_can_send(member, conversation, body, attachments, system?, user_id),
         {:ok, message} <-
           create_message(
             conversation_id,
             user_id,
             body,
             if(system?, do: %{"system" => true}, else: %{"format" => @message_format}),
             attachments
           ) do
      _ = touch_conversation(conversation)
      broadcast(conversation_id)
      {:ok, message}
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

  def rename_conversation(conversation_id, actor_id, title) do
    title = title |> to_string() |> String.trim() |> String.slice(0, 200)

    with :ok <- Mafia.WriteGate.ensure_enabled(),
         {:ok, conversation} <- Ash.get(Conversation, conversation_id, authorize?: false),
         :ok <- authorize_membership_sync(conversation, actor_id) do
      if conversation.title == title do
        {:ok, conversation}
      else
        conversation
        |> Ash.Changeset.for_update(:update, %{title: title})
        |> Ash.update(authorize?: false)
        |> tap(fn result -> if match?({:ok, _}, result), do: broadcast(conversation_id) end)
      end
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
         :ok <- authorize_membership_sync(conversation, actor_id),
         {:ok, updated} <-
           conversation
           |> Ash.Changeset.for_update(:update, %{is_archived: true})
           |> Ash.update(authorize?: false) do
      broadcast(conversation_id)
      {:ok, updated}
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

  def valid_gif_url?(url) when is_binary(url) do
    url = String.trim(url)

    byte_size(url) <= @gif_url_max_length and not Regex.match?(~r/[\s\x00-\x1F\x7F]/u, url) and
      case URI.parse(url) do
        %URI{scheme: scheme, host: host, path: path, userinfo: nil}
        when is_binary(scheme) and is_binary(host) and host != "" and is_binary(path) ->
          String.downcase(scheme) == "https" and
            String.ends_with?(String.downcase(path), ".gif")

        _ ->
          false
      end
  end

  def valid_gif_url?(_), do: false

  def subscribe(conversation_id) do
    Phoenix.PubSub.subscribe(Mafia.PubSub, "conversation:#{conversation_id}")
  end

  @doc "Publishes a refresh after a caller-owned database transaction commits."
  def refresh_conversation(conversation_id) do
    broadcast(conversation_id)
    :ok
  end

  defp add_members(conversation_id, creator_id, member_ids),
    do: add_members(conversation_id, creator_id, member_ids, [], true)

  defp direct_conversation_for(creator_id, recipient_id) do
    desired_members = MapSet.new([creator_id, recipient_id])

    creator_id
    |> list_user_conversations()
    |> Enum.filter(&(&1.kind == :direct))
    |> Ash.load!(:members, authorize?: false)
    |> Enum.find(fn conversation ->
      MapSet.new(conversation.members, & &1.user_id) == desired_members
    end)
  end

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

  defp create_message(conversation_id, user_id, body, metadata, attachments) do
    Message
    |> Ash.Changeset.for_create(:create, %{
      conversation_id: conversation_id,
      user_id: user_id,
      body: body,
      json_metadata: metadata,
      attachments: attachments
    })
    |> Ash.create(authorize?: false)
  end

  defp touch_conversation(conversation) do
    conversation
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:updated_at, DateTime.utc_now())
    |> Ash.update(authorize?: false)
  end

  defp verify_can_send(_member, %{is_archived: true}, _body, _attachments, _system?, _user_id),
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

  defp verify_can_send(%{role: :admin}, _conversation, body, attachments, true, _user_id),
    do: validate_message(body, attachments)

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
      validate_message(body, attachments)
    end
  end

  defp validate_message("", []), do: {:error, :empty_message}

  defp validate_message(body, _attachments) when byte_size(body) > 10_000,
    do: {:error, :message_too_long}

  defp validate_message(_body, _attachments), do: :ok

  defp gif_attachments(nil), do: {:ok, []}

  defp gif_attachments(url) do
    case url |> to_string() |> String.trim() do
      "" ->
        {:ok, []}

      url when byte_size(url) <= @gif_url_max_length ->
        if valid_gif_url?(url),
          do: {:ok, [%{"type" => "gif", "url" => url}]},
          else: {:error, :invalid_gif}

      _ ->
        {:error, :invalid_gif}
    end
  end

  defp validate_topic_title(""), do: {:error, :empty_title}

  defp validate_topic_title(title) do
    if String.length(title) > @forum_title_max_length,
      do: {:error, :title_too_long},
      else: :ok
  end

  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) || ""

  defp maybe_rate_limit_send(true, _conversation_id, _user_id), do: :ok

  defp maybe_rate_limit_send(false, conversation_id, user_id) do
    with :ok <-
           rate_limit(
             "chat:send:#{user_id}:#{conversation_id}",
             @send_rate_window,
             @send_rate_limit
           ) do
      rate_limit("chat:send:#{user_id}", @send_rate_window, @global_send_rate_limit)
    end
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

  defp rate_limit_direct_start(user_id) do
    rate_limit(
      "chat:direct-start:#{user_id}",
      @direct_start_rate_window,
      @direct_start_rate_limit
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
              faction_matches? =
                Map.get(conversation.metadata || %{}, "channel") != "faction" or
                  GameRules.canonical_faction_key(player.alignment) ==
                    GameRules.canonical_faction_key(
                      Map.get(conversation.metadata || %{}, "faction")
                    )

              required =
                cond do
                  private_game_channel?(conversation) and capability == "post_public" ->
                    ["private_chat"]

                  private_game_channel?(conversation) ->
                    ["private_chat", capability]

                  true ->
                    [capability]
                end

              if faction_matches? and
                   Enum.all?(required, &GameRules.capability?(game.ruleset, player, &1)),
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
    channel = Map.get(metadata, "channel")

    phase_matches? =
      channel != "side_chat" or
        Map.get(metadata, "phase_number") == game.phase_number

    policy_open? =
      case channel do
        "faction" ->
          GameRules.faction_chat_allowed?(
            game.ruleset,
            Map.get(metadata, "faction"),
            game.status
          )

        "side_chat" ->
          GameRules.private_chat_allowed?(game.ruleset, game.status)

        _ ->
          false
      end

    game.status in [:day, :night] and phase_matches? and policy_open?
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
end
