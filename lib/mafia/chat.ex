defmodule Mafia.Chat do
  @moduledoc "Mafia-scoped group chat, membership, and reactions."

  alias Mafia.Accounts
  alias Mafia.Chat.Resources.{Conversation, ConversationMember, Message, MessageReaction}
  alias Mafia.Repo

  require Ash.Query

  @allowed_reactions ["👍", "👎", "😂", "❤️", "🤔", "🎉"]
  @send_rate_window :timer.seconds(10)
  @send_rate_limit 10
  @reaction_rate_window :timer.seconds(10)
  @reaction_rate_limit 30

  def allowed_reactions, do: @allowed_reactions

  def create_group_conversation(creator_id, member_ids, opts \\ []) do
    with :ok <- Mafia.WriteGate.ensure_enabled(),
         %{} <- Accounts.get_user(creator_id) do
      Repo.transaction(fn ->
        with {:ok, conversation} <-
               Conversation
               |> Ash.Changeset.for_create(:create, %{
                 kind: :group,
                 creator_id: creator_id,
                 title: Keyword.get(opts, :title),
                 metadata: Keyword.get(opts, :metadata, %{})
               })
               |> Ash.create(authorize?: false),
             :ok <- add_members(conversation.id, creator_id, member_ids) do
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
    |> Enum.reject(&(&1.is_archived or not mafia_conversation?(&1)))
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  def get_conversation_for_user(conversation_id, user_id) do
    with {:ok, _member} <- membership(conversation_id, user_id),
         {:ok, conversation} <- Ash.get(Conversation, conversation_id, authorize?: false),
         {:ok, loaded} <- Ash.load(conversation, [members: [:user]], authorize?: false) do
      {:ok, loaded}
    else
      _ -> {:error, :not_found}
    end
  end

  def list_messages(conversation_id, user_id) do
    with {:ok, _member} <- membership(conversation_id, user_id) do
      Message
      |> Ash.Query.filter(conversation_id == ^conversation_id and is_nil(deleted_at))
      |> Ash.Query.sort(created_at: :asc)
      |> Ash.Query.load([:user, reactions: [:user]])
      |> Ash.read(authorize?: false)
    end
  end

  def send_message(conversation_id, user_id, body, opts \\ []) do
    system? = Keyword.get(opts, :system, false)
    body = body |> to_string() |> String.trim()

    with :ok <- Mafia.WriteGate.ensure_enabled(),
         {:ok, member} <- membership(conversation_id, user_id),
         :ok <- maybe_rate_limit_send(system?, conversation_id, user_id),
         {:ok, conversation} <- Ash.get(Conversation, conversation_id, authorize?: false),
         :ok <- verify_can_send(member, conversation, body, system?),
         {:ok, message} <-
           Message
           |> Ash.Changeset.for_create(:create, %{
             conversation_id: conversation_id,
             user_id: user_id,
             body: body,
             json_metadata: if(system?, do: %{"system" => true}, else: %{})
           })
           |> Ash.create(authorize?: false) do
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
         {:ok, _admin} <- admin_membership(conversation_id, actor_id),
         {:ok, conversation} <- Ash.get(Conversation, conversation_id, authorize?: false),
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
         :ok <- verify_can_react(member),
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

  defp add_members(conversation_id, creator_id, member_ids) do
    [creator_id | member_ids]
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn user_id, :ok ->
      attrs = %{
        conversation_id: conversation_id,
        user_id: user_id,
        role: if(user_id == creator_id, do: :admin, else: :member)
      }

      case ConversationMember
           |> Ash.Changeset.for_create(:create, attrs)
           |> Ash.create(authorize?: false) do
        {:ok, _member} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

  defp verify_can_send(%{role: :spectator}, _conversation, _body, _system?),
    do: {:error, :read_only}

  defp verify_can_send(%{shadow_muted: true}, _conversation, _body, _system?),
    do: {:error, :muted}

  defp verify_can_send(%{role: :admin}, _conversation, body, true),
    do: validate_body(body)

  defp verify_can_send(_member, %{is_read_only: true}, _body, _system?),
    do: {:error, :read_only}

  defp verify_can_send(_member, _conversation, body, _system?), do: validate_body(body)

  defp validate_body(""), do: {:error, :empty_message}
  defp validate_body(body) when byte_size(body) > 10_000, do: {:error, :message_too_long}
  defp validate_body(_), do: :ok

  defp maybe_rate_limit_send(true, _conversation_id, _user_id), do: :ok

  defp maybe_rate_limit_send(false, conversation_id, user_id) do
    rate_limit(
      "chat:send:#{user_id}:#{conversation_id}",
      @send_rate_window,
      @send_rate_limit
    )
  end

  defp rate_limit_reaction(conversation_id, user_id) do
    rate_limit(
      "chat:reaction:#{user_id}:#{conversation_id}",
      @reaction_rate_window,
      @reaction_rate_limit
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

  defp verify_can_react(%{role: :spectator}), do: {:error, :read_only}
  defp verify_can_react(%{shadow_muted: true}), do: {:error, :muted}
  defp verify_can_react(_), do: :ok

  defp mafia_conversation?(%{metadata: metadata}) do
    is_map(metadata) and is_binary(Map.get(metadata, "mafia_game_id"))
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
