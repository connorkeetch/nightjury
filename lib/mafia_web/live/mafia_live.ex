defmodule MafiaWeb.MafiaLive do
  @moduledoc """
  Mafia lobby: browse open games and host a new one. Public (guests can browse);
  hosting requires being logged in.
  """
  use MafiaWeb, :live_view

  alias Mafia.Games

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Mafia.PubSub, "mafia:lobby")

    {:ok,
     socket
     |> assign(:page_title, "Mafia")
     |> assign(:title, "")
     |> assign(:lobby_type, "open")
     |> load_games()}
  end

  @impl true
  def handle_event("validate", %{"title" => title, "lobby_type" => lobby_type}, socket) do
    {:noreply, assign(socket, title: title, lobby_type: lobby_type)}
  end

  def handle_event("create_game", %{"title" => title, "lobby_type" => lobby_type}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Log in to host a game.")}

      user ->
        attrs = %{
          title: blank_to_nil(title),
          ruleset: Map.put(Games.default_ruleset(), "lobby_type", lobby_type)
        }

        case Games.create_game(user.id, attrs) do
          {:ok, game} ->
            # Host joins their own lobby is optional; mod is a neutral overseer.
            {:noreply, push_navigate(socket, to: ~p"/mafia/#{game.id}")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not create the game.")}
        end
    end
  end

  @impl true
  def handle_info(:games_changed, socket), do: {:noreply, load_games(socket)}

  defp load_games(socket), do: assign(socket, :games, Games.list_open_games())

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(s), do: s

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto px-4 py-6 space-y-8">
      <div>
        <h1 class="text-2xl font-bold text-[color:var(--text)]">Mafia</h1>
        <p class="text-[color:var(--text-muted)] mt-1">
          A play-by-post game of hidden roles. A human moderator runs each game;
          the site handles the vote count, the day/night clock, and silencing the dead.
        </p>
      </div>

      <%= if @current_user do %>
        <form
          id="mafia-create-form"
          phx-change="validate"
          phx-submit="create_game"
          class="rounded-lg border border-[color:var(--border)] bg-[color:var(--surface-1)] p-4 space-y-4"
        >
          <h2 class="font-semibold text-[color:var(--text)]">Host a new game</h2>
          <div class="flex flex-col sm:flex-row gap-3">
            <input
              type="text"
              name="title"
              value={@title}
              placeholder="Game title (optional)"
              maxlength="120"
              class="flex-1 rounded-md border border-[color:var(--border)] bg-[color:var(--surface-2)] px-3 py-2 text-[color:var(--text)]"
            />
            <select
              name="lobby_type"
              class="rounded-md border border-[color:var(--border)] bg-[color:var(--surface-2)] px-3 py-2 text-[color:var(--text)]"
            >
              <option value="open" selected={@lobby_type == "open"}>Open lobby</option>
              <option value="invite" selected={@lobby_type == "invite"}>Invite only</option>
            </select>
            <button
              type="submit"
              class="rounded-md bg-[color:var(--color-primary)] px-4 py-2 font-medium text-[color:var(--color-on-primary)] whitespace-nowrap"
            >
              Create game
            </button>
          </div>
          <p class="text-xs text-[color:var(--text-muted)]">
            You'll be the moderator: assign roles, then start the game. The mod doesn't play.
          </p>
        </form>
      <% else %>
        <div class="rounded-lg border border-[color:var(--border)] bg-[color:var(--surface-1)] p-4">
          <.link navigate={~p"/users/log-in"} class="text-[color:var(--link)] font-medium">
            Log in
          </.link>
          <span class="text-[color:var(--text-muted)]">to host a game.</span>
        </div>
      <% end %>

      <div class="space-y-3">
        <h2 class="font-semibold text-[color:var(--text)]">Open games</h2>
        <%= if @games == [] do %>
          <p class="text-[color:var(--text-muted)]">
            No open games on file. The moderator's chair is available.
          </p>
        <% else %>
          <ul class="space-y-2">
            <li
              :for={game <- @games}
              class="flex items-center justify-between rounded-lg border border-[color:var(--border)] bg-[color:var(--surface-1)] p-3"
            >
              <div>
                <div class="font-medium text-[color:var(--text)]">
                  {game.title || "Untitled game"}
                </div>
                <div class="text-xs text-[color:var(--text-muted)]">In setup · open lobby</div>
              </div>
              <.link
                navigate={~p"/mafia/#{game.id}"}
                class="rounded-md border border-[color:var(--border)] px-3 py-1.5 text-sm text-[color:var(--text)] hover:bg-[color:var(--surface-2)]"
              >
                View
              </.link>
            </li>
          </ul>
        <% end %>
      </div>
    </div>
    """
  end
end
