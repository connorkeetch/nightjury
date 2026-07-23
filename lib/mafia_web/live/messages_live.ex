defmodule MafiaWeb.MessagesLive do
  use MafiaWeb, :live_view

  alias Mafia.Chat

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Chat.subscribe_user_conversations(socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(:page_title, "Messages")
     |> assign(:group_form, group_form())
     |> assign(:conversations, Chat.list_user_conversations(socket.assigns.current_user.id))}
  end

  @impl true
  def handle_event("create_group", %{"group" => attrs}, socket) do
    case Chat.create_group_conversation_by_usernames(
           socket.assigns.current_user.id,
           attrs
         ) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Group chat created.")
         |> push_navigate(to: ~p"/messages/#{conversation.id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:group_form, group_form(attrs))
         |> put_flash(:error, chat_error(reason))}
    end
  end

  @impl true
  def handle_info(:conversations_changed, socket) do
    {:noreply,
     assign(
       socket,
       :conversations,
       Chat.list_user_conversations(socket.assigns.current_user.id)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto max-w-4xl space-y-6">
      <.header>
        Your conversations
        <:subtitle>Group chats, Town Squares, and private faction rooms.</:subtitle>
      </.header>

      <details class="panel">
        <summary class="cursor-pointer font-semibold text-[color:var(--text)]">
          New group chat
        </summary>
        <.form
          for={@group_form}
          id="group-chat-form"
          phx-submit="create_group"
          class="mt-4 space-y-4"
        >
          <.input
            field={@group_form[:title]}
            label="Chat title"
            maxlength="120"
            required
            placeholder="Weekend game crew"
          />
          <.input
            field={@group_form[:members]}
            label="Usernames"
            required
            placeholder="alice, bob, charlie"
          />
          <p class="text-xs leading-5 text-[color:var(--text-muted)]">
            Separate usernames with commas or spaces. You are added automatically.
          </p>
          <.button variant="primary" phx-disable-with="Creating…">
            <.icon name="hero-user-group" class="size-4" /> Create group chat
          </.button>
        </.form>
      </details>

      <div :if={@conversations == []} class="empty-state">
        <div>
          <span class="empty-state-icon" aria-hidden="true">
            <.icon name="hero-chat-bubble-left-right" class="size-6" />
          </span>
          <p class="font-semibold text-[color:var(--text)]">No open conversations</p>
          <p class="mt-1 text-sm">
            Create a group chat, or join a game to open its conversation rooms.
          </p>
          <.link navigate={~p"/"} class="btn btn-secondary mt-4">Browse games</.link>
        </div>
      </div>

      <div class="space-y-3">
        <.link
          :for={conversation <- @conversations}
          navigate={~p"/messages/#{conversation.id}"}
          class="panel panel-interactive flex items-center justify-between gap-4 no-underline"
        >
          <div class="flex min-w-0 items-center gap-3">
            <span class="phase-icon shrink-0" aria-hidden="true">
              <.icon name="hero-chat-bubble-oval-left-ellipsis" class="size-5" />
            </span>
            <div class="min-w-0">
              <p class="truncate font-semibold text-[color:var(--text)]">
                {conversation.title || "Mafia chat"}
              </p>
              <p class="mt-1 text-sm text-[color:var(--text-muted)]">
                {if conversation.is_read_only,
                  do: "Read-only between phases",
                  else: "Open for replies"}
              </p>
            </div>
          </div>
          <.icon name="hero-chevron-right" class="size-5 shrink-0 text-[color:var(--text-muted)]" />
        </.link>
      </div>
    </section>
    """
  end

  defp group_form(params \\ %{"title" => "", "members" => ""}),
    do: to_form(params, as: :group)

  defp chat_error({:user_not_found, username}), do: "No user named #{username} was found."
  defp chat_error(:empty_title), do: "Give the group chat a title."
  defp chat_error(:title_too_long), do: "Keep the title to 120 characters."
  defp chat_error(:members_required), do: "Add at least one other user."
  defp chat_error(:too_many_members), do: "A group chat can include up to 25 other users."
  defp chat_error(:rate_limited), do: "Slow down and try again in a few minutes."
  defp chat_error(_reason), do: "Could not create that group chat."
end
