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
        <.link navigate={~p"/messages"} aria-label="Back to messages">←</.link>
        <div>
          <h1 class="text-xl font-semibold">{@conversation.title || "Mafia chat"}</h1>
          <p :if={@conversation.is_read_only} class="text-sm text-[color:var(--warning-text)]">
            This thread is locked until the next day phase.
          </p>
        </div>
      </header>

      <div id="messages" class="panel min-h-80 space-y-5">
        <p :if={@messages == []} class="text-center text-[color:var(--text-muted)]">
          No messages yet.
        </p>

        <article :for={message <- @messages} id={"message-#{message.id}"} class="group">
          <div class="flex items-baseline gap-2">
            <.link
              navigate={~p"/users/#{message.user.username}"}
              class="font-semibold text-[color:var(--text)]"
            >
              {message.user.username}
            </.link>
            <time class="text-xs text-[color:var(--text-muted)]">
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
                "min-h-8 rounded-full border border-[color:var(--border)] px-2 text-xs",
                reacted?(message, @current_user.id, emoji) && "bg-[color:var(--surface-2)]"
              ]}
              aria-label={"React #{emoji}"}
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
        class="flex gap-2"
      >
        <.input
          name="message[body]"
          value={@message}
          aria-label="Message"
          placeholder={
            if @conversation.is_read_only, do: "Thread is read-only", else: "Write a message…"
          }
          disabled={@conversation.is_read_only}
        />
        <.button variant="primary" disabled={@conversation.is_read_only}>Send</.button>
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
