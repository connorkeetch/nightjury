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
     |> assign(:page_title, "Games")
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
    <div class="mx-auto max-w-5xl space-y-10">
      <section class="lobby-hero">
        <div>
          <p class="eyebrow">Moderated social deduction</p>
          <h1 class="display-heading">One verdict before dawn.</h1>
          <p class="lede mt-6">
            Night Jury is a play-by-post game of hidden roles and public arguments. A human
            moderator runs each game; we keep the vote count, the day/night clock, and the dead
            respectfully silent.
          </p>
          <div class="mt-6 flex flex-wrap gap-2" aria-label="Game features">
            <span class="status-chip"><.icon name="hero-user-group" class="size-4" /> Human run</span>
            <span class="status-chip"><.icon name="hero-clock" class="size-4" /> Asynchronous</span>
            <span class="status-chip status-chip-wax">
              <.icon name="hero-eye-slash" class="size-4" /> Hidden roles
            </span>
          </div>
        </div>
        <div class="hero-seal" aria-hidden="true">
          <.icon name="hero-scale" class="size-14" />
        </div>
      </section>

      <div class="grid gap-6 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)] lg:items-start">
        <%= if @current_user do %>
          <form
            id="mafia-create-form"
            phx-change="validate"
            phx-submit="create_game"
            class="panel space-y-5"
          >
            <div class="flex items-start gap-3">
              <span class="phase-icon size-10 shrink-0" aria-hidden="true">
                <.icon name="hero-key" class="size-5" />
              </span>
              <div>
                <h2 class="section-heading">Take the moderator's chair</h2>
                <p class="mt-1 text-sm text-[color:var(--text-muted)]">
                  Name the game, choose the door policy, then assign roles inside.
                </p>
              </div>
            </div>

            <label class="block">
              <span class="mb-1.5 block text-sm font-semibold">Game title</span>
              <input
                type="text"
                name="title"
                value={@title}
                placeholder="The Long Night"
                maxlength="120"
                class="input"
              />
            </label>

            <label class="block">
              <span class="mb-1.5 block text-sm font-semibold">Who can join?</span>
              <select name="lobby_type" class="input">
                <option value="open" selected={@lobby_type == "open"}>Anyone — open lobby</option>
                <option value="invite" selected={@lobby_type == "invite"}>
                  Invited players only
                </option>
              </select>
            </label>

            <button
              type="submit"
              class="btn btn-primary w-full"
              phx-disable-with="Opening the room…"
            >
              <.icon name="hero-plus" class="size-5" /> Create game
            </button>
            <p class="text-xs leading-5 text-[color:var(--text-muted)]">
              The moderator oversees the room and doesn't take a player role.
            </p>
          </form>
        <% else %>
          <aside class="panel">
            <span class="phase-icon mb-4" aria-hidden="true">
              <.icon name="hero-key" class="size-5" />
            </span>
            <h2 class="section-heading">The chair is open</h2>
            <p class="mt-2 text-sm leading-6 text-[color:var(--text-muted)]">
              Sign in to host a room, invite players, and keep the night moving.
            </p>
            <.link navigate={~p"/users/log-in"} class="btn btn-primary mt-5">
              Log in to host <.icon name="hero-arrow-right" class="size-4" />
            </.link>
          </aside>
        <% end %>

        <section aria-labelledby="open-games-heading">
          <div class="mb-4 flex items-center justify-between gap-4">
            <div>
              <p class="eyebrow">Now assembling</p>
              <h2 id="open-games-heading" class="section-heading mt-2">Open games</h2>
            </div>
            <span class="status-chip">{length(@games)} listed</span>
          </div>

          <%= if @games == [] do %>
            <div class="empty-state">
              <div>
                <span class="empty-state-icon" aria-hidden="true">
                  <.icon name="hero-moon" class="size-6" />
                </span>
                <p class="font-semibold text-[color:var(--text)]">The room is quiet—for now.</p>
                <p class="mt-1 text-sm">No open games on file. The moderator's chair is available.</p>
              </div>
            </div>
          <% else %>
            <ul class="space-y-3">
              <li :for={game <- @games}>
                <.link
                  navigate={~p"/mafia/#{game.id}"}
                  class="panel panel-interactive flex items-center justify-between gap-4 no-underline"
                >
                  <div class="min-w-0">
                    <p class="truncate font-semibold text-[color:var(--text)]">
                      {game.title || "Untitled game"}
                    </p>
                    <p class="mt-1 text-xs text-[color:var(--text-muted)]">
                      In setup · {if Games.lobby_type(game) == "open",
                        do: "open lobby",
                        else: "invite only"}
                    </p>
                  </div>
                  <span class="flex shrink-0 items-center gap-2 text-sm font-semibold text-[color:var(--link)]">
                    Enter <.icon name="hero-arrow-right" class="size-4" />
                  </span>
                </.link>
              </li>
            </ul>
          <% end %>
        </section>
      </div>
    </div>
    """
  end
end
