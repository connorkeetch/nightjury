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
    <section class="mx-auto max-w-3xl">
      <.header>
        Mafia conversations
        <:subtitle>Town Squares and private Mafia rooms from games you belong to.</:subtitle>
      </.header>

      <div :if={@conversations == []} class="panel text-[color:var(--text-muted)]">
        Your game conversations will appear here after a moderator starts a game.
      </div>

      <div class="space-y-3">
        <.link
          :for={conversation <- @conversations}
          navigate={~p"/messages/#{conversation.id}"}
          class="panel block hover:border-[color:var(--link)]"
        >
          <p class="font-semibold text-[color:var(--text)]">{conversation.title || "Mafia chat"}</p>
          <p class="mt-1 text-sm text-[color:var(--text-muted)]">
            {if conversation.is_read_only, do: "Read-only between phases", else: "Open"}
          </p>
        </.link>
      </div>
    </section>
    """
  end
end
