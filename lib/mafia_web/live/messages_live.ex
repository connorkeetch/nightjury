defmodule MafiaWeb.MessagesLive do
  use MafiaWeb, :live_view

  alias Mafia.Chat

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Messages")
     |> assign(:conversations, Chat.list_user_conversations(socket.assigns.current_user.id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto max-w-4xl">
      <.header>
        Your conversations
        <:subtitle>Town Squares and private faction rooms from games you belong to.</:subtitle>
      </.header>

      <div :if={@conversations == []} class="empty-state">
        <div>
          <span class="empty-state-icon" aria-hidden="true">
            <.icon name="hero-chat-bubble-left-right" class="size-6" />
          </span>
          <p class="font-semibold text-[color:var(--text)]">No open conversations</p>
          <p class="mt-1 text-sm">
            Your game conversations will appear here after a moderator starts a game.
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
end
