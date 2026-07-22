defmodule MafiaWeb.ChatLive do
  use MafiaWeb, :live_view

  alias Mafia.Chat

  @impl true
  def mount(%{"conversation_id" => id}, _session, socket) do
    if connected?(socket), do: Chat.subscribe(id)

    {:ok,
     socket
     |> assign(:conversation_id, id)
     |> assign(:message, "")
     |> refresh()}
  end

  @impl true
  def handle_event("send_message", %{"message" => %{"body" => body}}, socket) do
    case Chat.send_message(socket.assigns.conversation_id, socket.assigns.current_user.id, body) do
      {:ok, _message} -> {:noreply, socket |> assign(:message, "") |> refresh()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, chat_error(reason))}
    end
  end

  def handle_event("react", %{"message-id" => message_id, "emoji" => emoji}, socket) do
    case Chat.toggle_reaction(message_id, socket.assigns.current_user.id, emoji) do
      {:ok, _} -> {:noreply, refresh(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, chat_error(reason))}
    end
  end

  @impl true
  def handle_info(:messages_changed, socket), do: {:noreply, refresh(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto flex max-w-4xl flex-col gap-4">
      <header class="flex items-center gap-3">
        <.link navigate={~p"/messages"} class="btn btn-quiet" aria-label="Back to messages">
          <.icon name="hero-arrow-left" class="size-4" />
        </.link>
        <div class="min-w-0">
          <p class="eyebrow">Conversation</p>
          <h1 class="section-heading mt-1 truncate">{@conversation.title || "Mafia chat"}</h1>
          <p :if={@conversation.is_read_only} class="text-sm text-[color:var(--warning-text)]">
            This thread is locked until the next day phase.
          </p>
        </div>
      </header>

      <div id="messages" class="panel min-h-80 space-y-5">
        <div :if={@messages == []} class="empty-state min-h-64 border-0 bg-transparent">
          <div>
            <span class="empty-state-icon" aria-hidden="true">
              <.icon name="hero-chat-bubble-bottom-center-text" class="size-6" />
            </span>
            <p class="font-semibold text-[color:var(--text)]">The floor is open.</p>
            <p class="mt-1 text-sm">No messages yet.</p>
          </div>
        </div>

        <article
          :for={message <- @messages}
          id={"message-#{message.id}"}
          class="group border-b border-[color:var(--border)] pb-5 last:border-0 last:pb-0"
        >
          <div class="flex items-baseline gap-2">
            <.link
              navigate={~p"/users/#{message.user.username}"}
              class="font-semibold text-[color:var(--text)]"
            >
              {message.user.username}
            </.link>
            <time
              datetime={DateTime.to_iso8601(message.created_at)}
              class="mono text-xs text-[color:var(--text-muted)]"
            >
              {Calendar.strftime(message.created_at, "%b %-d, %H:%M")}
            </time>
          </div>
          <p class={[
            "mt-1 whitespace-pre-wrap leading-6",
            (message.json_metadata || %{})["system"] &&
              "italic text-[color:var(--text-muted)]"
          ]}>
            {message.body}
          </p>
          <div class="mt-2 flex flex-wrap gap-1">
            <button
              :for={emoji <- Chat.allowed_reactions()}
              type="button"
              phx-click="react"
              phx-value-message-id={message.id}
              phx-value-emoji={emoji}
              class={[
                "min-h-9 rounded-full border border-[color:var(--border)] px-2 text-xs",
                reacted?(message, @current_user.id, emoji) && "bg-[color:var(--surface-2)]"
              ]}
              aria-label={"React with #{emoji}; #{reaction_count(message, emoji)} reactions"}
              aria-pressed={reacted?(message, @current_user.id, emoji)}
            >
              {emoji} {reaction_count(message, emoji)}
            </button>
          </div>
        </article>
      </div>

      <.form
        for={to_form(%{"body" => @message}, as: :message)}
        id="message-form"
        phx-submit="send_message"
        class="flex items-end gap-2"
      >
        <div class="min-w-0 flex-1">
          <.input
            name="message[body]"
            value={@message}
            aria-label="Message"
            placeholder={
              if @conversation.is_read_only, do: "Thread is read-only", else: "Write a message…"
            }
            disabled={@conversation.is_read_only}
          />
        </div>
        <.button
          variant="primary"
          disabled={@conversation.is_read_only}
          phx-disable-with="Sending…"
        >
          <.icon name="hero-paper-airplane" class="size-4" /> Send
        </.button>
      </.form>
    </section>
    """
  end

  defp refresh(socket) do
    user_id = socket.assigns.current_user.id
    id = socket.assigns.conversation_id

    with {:ok, conversation} <- Chat.get_conversation_for_user(id, user_id),
         {:ok, messages} <- Chat.list_messages(id, user_id) do
      socket
      |> assign(:page_title, conversation.title || "Messages")
      |> assign(:conversation, conversation)
      |> assign(:messages, messages)
    else
      _ ->
        socket
        |> put_flash(:error, "Conversation not found.")
        |> push_navigate(to: ~p"/messages")
    end
  end

  defp reacted?(message, user_id, emoji),
    do: Enum.any?(message.reactions, &(&1.user_id == user_id and &1.emoji == emoji))

  defp reaction_count(message, emoji), do: Enum.count(message.reactions, &(&1.emoji == emoji))

  defp chat_error(:muted), do: "You cannot post or react after elimination."
  defp chat_error(:read_only), do: "This conversation is read-only."
  defp chat_error(:empty_message), do: "Write a message first."
  defp chat_error(_), do: "That chat action could not be completed."
end
