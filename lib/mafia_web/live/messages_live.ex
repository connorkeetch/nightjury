defmodule MafiaWeb.MessagesLive do
  use MafiaWeb, :live_view

  alias Mafia.{Accounts, Chat}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Chat.subscribe_user_conversations(socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(:page_title, "Messages")
     |> assign_chat_form()
     |> assign(:user_suggestions, [])
     |> assign(:group_form, group_form())
     |> assign(:conversations, Chat.list_user_conversations(socket.assigns.current_user.id))}
  end

  @impl true
  def handle_event("suggest_users", %{"chat" => %{"username" => query}}, socket) do
    {:noreply, assign(socket, :user_suggestions, Accounts.search_users(query))}
  end

  @impl true
  def handle_event("start_chat", %{"chat" => %{"username" => username}}, socket) do
    current_user = socket.assigns.current_user
    username = String.trim(username)

    case Accounts.get_user_by_username(username) do
      nil ->
        {:noreply,
         socket
         |> assign_chat_form(username)
         |> put_flash(:error, "No active user has that exact username.")}

      %{id: id} when id == current_user.id ->
        {:noreply,
         socket
         |> assign_chat_form(username)
         |> put_flash(:error, "Choose someone other than yourself.")}

      recipient ->
        case Chat.start_direct_conversation(current_user.id, recipient.id) do
          {:ok, conversation} ->
            {:noreply, push_navigate(socket, to: ~p"/messages/#{conversation.id}")}

          {:error, :rate_limited} ->
            {:noreply, put_flash(socket, :error, "Slow down and try again in a few minutes.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not start that chat.")}
        end
    end
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
         |> put_flash(:error, group_error(reason))}
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
        <:subtitle>Private chats, group chats, and rooms from games you belong to.</:subtitle>
      </.header>

      <div class="grid gap-4 md:grid-cols-2">
        <div class="panel">
          <h2 class="font-semibold text-[color:var(--text)]">Start a private chat</h2>
          <.form
            for={@chat_form}
            id="start-chat-form"
            phx-change="suggest_users"
            phx-submit="start_chat"
            class="mt-3 flex items-end gap-2"
          >
            <div class="min-w-0 flex-1">
              <.input
                field={@chat_form[:username]}
                label="Username"
                placeholder="Search usernames"
                autocomplete="off"
                list="chat-user-suggestions"
                phx-debounce="200"
                required
              />
              <datalist id="chat-user-suggestions">
                <option :for={user <- @user_suggestions} value={user.username}></option>
              </datalist>
            </div>
            <.button variant="primary" phx-disable-with="Starting…">Start chat</.button>
          </.form>
        </div>

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
      </div>

      <div :if={@conversations == []} class="empty-state">
        <div>
          <span class="empty-state-icon" aria-hidden="true">
            <.icon name="hero-chat-bubble-left-right" class="size-6" />
          </span>
          <p class="font-semibold text-[color:var(--text)]">No open conversations</p>
          <p class="mt-1 text-sm">
            Start a private or group chat, or join a game to open its rooms.
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
                {conversation.title || "Chat"}
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

  defp assign_chat_form(socket, username \\ "") do
    assign(socket, :chat_form, to_form(%{"username" => username}, as: :chat))
  end

  defp group_form(params \\ %{"title" => "", "members" => ""}),
    do: to_form(params, as: :group)

  defp group_error({:user_not_found, username}), do: "No user named #{username} was found."
  defp group_error(:empty_title), do: "Give the group chat a title."
  defp group_error(:title_too_long), do: "Keep the title to 120 characters."
  defp group_error(:members_required), do: "Add at least one other user."
  defp group_error(:too_many_members), do: "A group chat can include up to 25 other users."
  defp group_error(:rate_limited), do: "Slow down and try again in a few minutes."
  defp group_error(_reason), do: "Could not create that group chat."
end
