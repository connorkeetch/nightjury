defmodule MafiaWeb.GameNotesLive do
  use MafiaWeb, :live_view

  alias Mafia.{GameRules, Games}
  import MafiaWeb.GameComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Games.get_game_for_view(id) do
      {:ok, game} ->
        user = socket.assigns.current_user

        if Enum.any?(game.players, &(&1.user_id == user.id)) do
          if connected?(socket), do: Games.subscribe(id)

          {:ok,
           socket
           |> assign(:page_title, "Notebook · #{game.title || "Untitled game"}")
           |> assign(:game, game)
           |> assign(:notes, normalize_notes(Games.notebook(game, user.id)))
           |> assign(:save_state, :saved)}
        else
          {:ok,
           socket
           |> put_flash(:error, "The private notebook is available to seated players.")
           |> push_navigate(to: ~p"/mafia/#{game.id}")}
        end

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "That game doesn't exist.")
         |> push_navigate(to: ~p"/mafia")}
    end
  end

  @impl true
  def handle_event("save_notes", %{"notes" => params}, socket) do
    notes = notes_from_form(params)
    game = socket.assigns.game
    user_id = socket.assigns.current_user.id

    case Games.save_notebook(game, user_id, notes) do
      {:ok, _saved} ->
        {:noreply, socket |> assign(:notes, notes) |> assign(:save_state, :saved)}

      :ok ->
        {:noreply, socket |> assign(:notes, notes) |> assign(:save_state, :saved)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:save_state, :error)
         |> put_flash(:error, humanize(reason))}
    end
  end

  @impl true
  def handle_info(_message, socket) do
    case Games.get_game_for_view(socket.assigns.game.id) do
      {:ok, game} -> {:noreply, assign(socket, :game, game)}
      {:error, _reason} -> {:noreply, push_navigate(socket, to: ~p"/mafia")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl space-y-6">
      <header class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p class="eyebrow">Private working papers</p>
          <h1 class="page-heading mt-2">Your notebook</h1>
          <p class="mt-3 max-w-2xl text-sm leading-6 text-[color:var(--text-muted)]">
            Keep a general theory and private notes on every player. The moderator and other
            players cannot read this page.
          </p>
        </div>
        <.game_nav game={@game} current={:notes} show_notes={true} />
      </header>

      <section class="phase-banner" aria-label="Notebook privacy and save status">
        <span class="phase-icon" aria-hidden="true">
          <.icon name="hero-lock-closed" class="size-5" />
        </span>
        <div class="min-w-0">
          <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-[color:var(--text-muted)]">
            Private to you
          </p>
          <p class="mt-1 text-sm text-[color:var(--text-soft)]">
            Notes stay attached to this game as its roster changes.
          </p>
        </div>
        <span
          class={[
            "status-chip",
            @save_state == :error && "status-chip-wax"
          ]}
          aria-live="polite"
        >
          {save_label(@save_state)}
        </span>
      </section>

      <form
        id="game-notebook-form"
        phx-change="save_notes"
        phx-submit="save_notes"
        class="space-y-6"
      >
        <section class="panel role-card">
          <div class="flex items-start gap-3">
            <span class="phase-icon shrink-0" aria-hidden="true">
              <.icon name="hero-light-bulb" class="size-5" />
            </span>
            <div>
              <p class="eyebrow">Working theory</p>
              <h2 class="section-heading mt-2">General notes</h2>
            </div>
          </div>
          <div class="mt-4">
            <.input
              type="textarea"
              name="notes[general]"
              label="Your general game notes"
              value={Map.get(@notes, "general", "")}
              rows="7"
              maxlength="20000"
              phx-debounce="700"
              placeholder="Claims, timelines, vote patterns, open questions…"
            />
          </div>
        </section>

        <section aria-labelledby="player-notes-heading">
          <div class="mb-4 flex flex-wrap items-end justify-between gap-3">
            <div>
              <p class="eyebrow">Roster ledger</p>
              <h2 id="player-notes-heading" class="section-heading mt-2">Player notes</h2>
            </div>
            <span class="status-chip">{length(@game.players)} players</span>
          </div>

          <div class="grid gap-4 md:grid-cols-2">
            <article :for={player <- @game.players} class="panel">
              <div class="mb-3 flex items-center justify-between gap-3">
                <div class="flex min-w-0 items-center gap-2">
                  <span class="phase-icon size-9 shrink-0" aria-hidden="true">
                    <.icon name="hero-user" class="size-4" />
                  </span>
                  <h3 class="truncate font-semibold text-[color:var(--text)]">
                    {user_name(player.user)}
                  </h3>
                </div>
                <span class={[
                  "status-chip shrink-0",
                  GameRules.player_status(player) != "active" && "status-chip-wax"
                ]}>
                  {status_label(player)}
                </span>
              </div>
              <.input
                type="textarea"
                name={"notes[players][#{player.id}]"}
                label={"Private notes about #{user_name(player.user)}"}
                value={Map.get(@notes, to_string(player.id), "")}
                rows="4"
                maxlength="5000"
                phx-debounce="700"
                placeholder="Claims, reads, contradictions, connections…"
              />
            </article>
          </div>
        </section>

        <div class="flex flex-col gap-3 border-t border-[color:var(--border)] pt-4 sm:flex-row sm:items-center sm:justify-between">
          <p class="text-xs leading-5 text-[color:var(--text-muted)]" aria-live="polite">
            {save_detail(@save_state)}
          </p>
          <button type="submit" class="btn btn-secondary shrink-0" phx-disable-with="Saving…">
            <.icon name="hero-check" class="size-4" /> Save now
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp notes_from_form(params) do
    params
    |> Map.get("players", %{})
    |> Map.new(fn {player_id, body} -> {to_string(player_id), to_string(body)} end)
    |> Map.put("general", to_string(Map.get(params, "general", "")))
  end

  defp normalize_notes({:ok, notes}) when is_map(notes), do: normalize_notes(notes)

  defp normalize_notes(notes) when is_map(notes) do
    Map.new(notes, fn {key, value} -> {to_string(key), to_string(value || "")} end)
  end

  defp normalize_notes(_), do: %{"general" => ""}

  defp user_name(%Ash.NotLoaded{}), do: "Player"
  defp user_name(nil), do: "Player"
  defp user_name(user), do: Map.get(user, :username) || "Player"

  defp status_label(player) do
    case GameRules.player_status(player) do
      "active" -> "Active"
      "dead" -> "Eliminated"
      "removed" -> "Removed"
      "spectator" -> "Spectator"
    end
  end

  defp save_label(:error), do: "Save failed"
  defp save_label(_), do: "Saved"

  defp save_detail(:error), do: "Your last change was not saved. Try Save now again."
  defp save_detail(_), do: "Changes save automatically after you pause typing."

  defp humanize(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  defp humanize(reason), do: inspect(reason)
end
