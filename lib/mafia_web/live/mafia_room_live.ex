defmodule MafiaWeb.MafiaRoomLive do
  @moduledoc """
  A single Mafia game. Public (spectators can watch); actions are gated by login,
  membership, and — for moderation — being the host. The host panel is folded in
  here rather than a separate dashboard.
  """
  use MafiaWeb, :live_view

  alias Mafia.Games

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Games.get_game_for_view(id) do
      {:ok, _game} ->
        if connected?(socket) do
          Games.subscribe(id)
          # Re-render the deadline countdown periodically (no DB hit on tick).
          :timer.send_interval(30_000, self(), :tick)
        end

        {:ok, socket |> assign(:game_id, id) |> assign(:now, DateTime.utc_now()) |> refresh()}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "That game doesn't exist.")
         |> push_navigate(to: ~p"/mafia")}
    end
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event(_evt, _params, %{assigns: %{current_user: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "Log in to take part.")}
  end

  def handle_event("join", _params, socket) do
    handle_result(Games.join_game(socket.assigns.game, socket.assigns.current_user.id), socket)
  end

  def handle_event("leave", _params, socket) do
    handle_result(Games.leave_game(socket.assigns.game, socket.assigns.current_user.id), socket)
  end

  def handle_event("start", _params, socket) do
    handle_result(Games.start_game(socket.assigns.game, socket.assigns.current_user.id), socket)
  end

  def handle_event("assign_roles", %{"roles" => roles}, socket) do
    players = socket.assigns.game.players

    assignments =
      Enum.map(roles, fn {player_id, attrs} ->
        existing = Enum.find(players, &(&1.id == player_id))

        %{
          player_id: player_id,
          role_name: blank_to_nil(attrs["role_name"]),
          alignment: parse_alignment(attrs["alignment"]),
          # Preserve the stored PM when the field isn't submitted, so saving
          # roles can't silently null it out.
          role_pm_body:
            if(Map.has_key?(attrs, "pm"),
              do: blank_to_nil(attrs["pm"]),
              else: existing && existing.role_pm_body
            )
        }
      end)

    handle_result(
      Games.assign_roles(socket.assigns.game, socket.assigns.current_user.id, assignments),
      socket
    )
  end

  def handle_event("cast_vote", %{"target" => target}, socket) do
    target_id = if target == "no_lynch", do: nil, else: target

    handle_result(
      Games.cast_vote(socket.assigns.game, socket.assigns.current_user.id, target_id),
      socket
    )
  end

  def handle_event("retract_vote", _params, socket) do
    handle_result(Games.retract_vote(socket.assigns.game, socket.assigns.current_user.id), socket)
  end

  def handle_event("submit_night_action", %{"action_kind" => kind, "target" => target}, socket) do
    target_id = if target in ["none", ""], do: nil, else: target

    handle_result(
      Games.submit_night_action(
        socket.assigns.game,
        socket.assigns.current_user.id,
        kind,
        target_id
      ),
      socket
    )
  end

  def handle_event("resolve_night_action", %{"action_id" => id, "result" => result}, socket) do
    handle_result(
      Games.resolve_night_action(socket.assigns.game, id, result, socket.assigns.current_user.id),
      socket
    )
  end

  def handle_event("eliminate", %{"player_id" => pid, "reason" => reason}, socket) do
    handle_result(
      Games.eliminate(
        socket.assigns.game,
        pid,
        parse_reason(reason),
        socket.assigns.current_user.id
      ),
      socket
    )
  end

  def handle_event("kick", %{"player_id" => pid}, socket) do
    game = socket.assigns.game

    case Enum.find(game.players, &(&1.id == pid)) do
      nil ->
        {:noreply, socket}

      player ->
        handle_result(Games.kick_player(game, player, socket.assigns.current_user.id), socket)
    end
  end

  def handle_event("add_player", %{"name" => name}, socket) do
    handle_result(
      Games.add_player_by_name(socket.assigns.game, socket.assigns.current_user.id, name),
      socket
    )
  end

  def handle_event("open_next_day", _params, socket) do
    handle_result(
      Games.open_next_day(socket.assigns.game, socket.assigns.current_user.id),
      socket
    )
  end

  def handle_event("delete_game", _params, socket) do
    case Games.delete_game(socket.assigns.game, socket.assigns.current_user.id) do
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize(reason))}

      _ok ->
        {:noreply, socket |> put_flash(:info, "Game deleted.") |> push_navigate(to: ~p"/mafia")}
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub — any change just reloads
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}
  def handle_info(_message, socket), do: {:noreply, refresh(socket)}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp handle_result({:ok, _}, socket), do: {:noreply, refresh(socket)}
  defp handle_result(:ok, socket), do: {:noreply, refresh(socket)}

  defp handle_result({:error, reason}, socket) do
    {:noreply, socket |> put_flash(:error, humanize(reason)) |> refresh()}
  end

  defp refresh(socket) do
    case Games.get_game_for_view(socket.assigns.game_id) do
      {:ok, game} ->
        user = socket.assigns[:current_user]
        is_host = user && user.id == game.host_id
        my_player = user && Enum.find(game.players, &(&1.user_id == user.id))

        socket
        |> assign(:game, game)
        |> assign(:page_title, game.title || "Mafia")
        |> assign(:is_host, !!is_host)
        |> assign(:my_player, my_player)
        |> assign(:vote_counts, if(game.status == :day, do: Games.vote_counts(game)))
        |> assign(
          :my_vote,
          if(game.status == :day && user, do: Games.voted_target(game, user.id))
        )
        |> assign(
          :night_actions,
          if(is_host && game.status == :night, do: Games.list_night_actions(game), else: [])
        )

      {:error, _} ->
        push_navigate(socket, to: ~p"/mafia")
    end
  end

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(s), do: s

  defp parse_alignment("town"), do: :town
  defp parse_alignment("mafia"), do: :mafia
  defp parse_alignment(_), do: nil

  defp parse_reason("night"), do: :night
  defp parse_reason(_), do: :modkill

  defp user_name(%Ash.NotLoaded{}), do: "Player"
  defp user_name(nil), do: "Player"
  # No email fallback — usernames are required (non-null), and an email must never
  # render as a display name to other players in the room.
  defp user_name(user), do: Map.get(user, :username) || "Player"

  defp living(players), do: Enum.filter(players, & &1.is_alive)

  defp day_number(%{phase_number: n}), do: div(n + 1, 2)

  defp deadline_text(nil), do: "no deadline"
  defp deadline_text(dt), do: Calendar.strftime(dt, "%b %d, %H:%M UTC")

  defp time_left(nil, _now), do: nil

  defp time_left(deadline, now) do
    secs = DateTime.diff(deadline, now)

    cond do
      secs <= 0 -> "past deadline"
      secs < 3600 -> "~#{div(secs, 60)}m left"
      true -> "~#{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m left"
    end
  end

  defp humanize(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  defp humanize(reason), do: inspect(reason)

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto px-4 py-6 space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-[color:var(--text)]">{@game.title || "Mafia"}</h1>
          <p class="text-sm text-[color:var(--text-muted)]">{status_line(assigns)}</p>
        </div>
        <div class="flex items-center gap-4">
          <button
            :if={@is_host}
            phx-click="delete_game"
            data-confirm="Delete this game permanently? This can't be undone."
            class="text-sm text-[color:var(--text-muted)] hover:text-red-400"
          >
            Delete game
          </button>
          <.link
            navigate={~p"/mafia"}
            class="text-sm text-[color:var(--text-muted)] hover:text-[color:var(--text)]"
          >
            ← All games
          </.link>
        </div>
      </div>

      <%= if @my_player && @my_player.role_name do %>
        <div class="rounded-lg border border-[color:var(--color-primary)] bg-[color:var(--surface-1)] p-3">
          <div class="text-xs uppercase tracking-wide text-[color:var(--text-muted)]">Your role</div>
          <div class="font-semibold text-[color:var(--text)]">
            {@my_player.role_name}
            <span class="text-[color:var(--text-muted)]">({@my_player.alignment})</span>
          </div>
          <p
            :if={@my_player.role_pm_body}
            class="text-sm text-[color:var(--text-muted)] mt-1 whitespace-pre-wrap"
          >
            {@my_player.role_pm_body}
          </p>
        </div>
      <% end %>

      {render_body(assigns)}
    </div>
    """
  end

  defp status_line(%{game: %{status: :setup}}),
    do: "In setup — waiting for the moderator to start."

  defp status_line(%{game: %{status: :finished} = g}),
    do: "Finished — the #{g.winner_faction} win."

  defp status_line(%{game: %{status: status} = g} = assigns) do
    left = time_left(g.phase_ends_at, assigns[:now] || DateTime.utc_now())

    "#{String.capitalize(to_string(status))} #{day_number(g)} · #{left} · deadline #{deadline_text(g.phase_ends_at)}"
  end

  # ---- setup ----------------------------------------------------------------

  defp render_body(%{game: %{status: :setup}} = assigns) do
    ~H"""
    <div class="space-y-6">
      <details class="rounded-lg border border-[color:var(--border)] bg-[color:var(--surface-1)] p-4">
        <summary class="font-semibold text-[color:var(--text)] cursor-pointer">
          How Mafia works
        </summary>
        <div class="text-sm text-[color:var(--text-muted)] mt-2 space-y-1">
          <p>
            Each day, everyone discusses in the Town Square and casts a vote to lynch one player.
            When a target hits the hammer (a majority) or the day deadline passes, they're out and
            their role is revealed.
          </p>
          <p>
            Each night the town sleeps: the mafia pick someone to eliminate, and players with night
            powers send their action to the moderator, who resolves it.
          </p>
          <p>Town wins by eliminating all mafia; the mafia win once they equal the town.</p>
        </div>
      </details>

      <div class="rounded-lg border border-[color:var(--border)] bg-[color:var(--surface-1)] p-4">
        <h2 class="font-semibold text-[color:var(--text)] mb-2">Players ({length(@game.players)})</h2>
        <ul class="divide-y divide-[color:var(--border)]">
          <li :for={p <- @game.players} class="flex items-center justify-between py-2">
            <span class="text-[color:var(--text)]">{user_name(p.user)}</span>
            <button
              :if={@is_host}
              phx-click="kick"
              phx-value-player_id={p.id}
              class="text-xs text-[color:var(--text-muted)] hover:text-red-400"
            >
              Remove
            </button>
          </li>
        </ul>
        <p :if={@game.players == []} class="text-[color:var(--text-muted)] text-sm">
          No players on file. The moderator is accepting names.
        </p>

        <div :if={@current_user && !@is_host} class="mt-3">
          <%= cond do %>
            <% @my_player -> %>
              <button phx-click="leave" class={btn_secondary()}>Leave</button>
            <% Games.lobby_type(@game) == "open" -> %>
              <button phx-click="join" class={btn_primary()}>Join game</button>
            <% true -> %>
              <span class="text-sm text-[color:var(--text-muted)]">
                Invite only — the moderator adds players.
              </span>
          <% end %>
        </div>
      </div>

      <div
        :if={@is_host}
        class="rounded-lg border border-[color:var(--border)] bg-[color:var(--surface-1)] p-4"
      >
        <h2 class="font-semibold text-[color:var(--text)] mb-2">Add a player</h2>
        <form phx-submit="add_player" class="flex gap-2">
          <input
            type="text"
            name="name"
            placeholder="Username or email"
            required
            class={input_class()}
          />
          <button type="submit" class={btn_secondary()}>Add</button>
        </form>
      </div>

      <%= if @is_host do %>
        <form
          phx-submit="assign_roles"
          class="rounded-lg border border-[color:var(--border)] bg-[color:var(--surface-1)] p-4 space-y-4"
        >
          <h2 class="font-semibold text-[color:var(--text)]">Assign roles, then start</h2>
          <p class="text-xs text-[color:var(--text-muted)]">
            Every player needs an alignment. The role name is free text — you resolve any powers by hand.
          </p>
          <div
            :for={p <- @game.players}
            class="space-y-1 border-b border-[color:var(--border)] pb-3 last:border-b-0"
          >
            <div class="grid grid-cols-1 sm:grid-cols-[1fr_8rem_1fr] gap-2 items-center">
              <div class="text-sm text-[color:var(--text)]">{user_name(p.user)}</div>
              <select name={"roles[#{p.id}][alignment]"} class={input_class()}>
                <option value="town" selected={p.alignment == :town}>Town</option>
                <option value="mafia" selected={p.alignment == :mafia}>Mafia</option>
              </select>
              <input
                type="text"
                name={"roles[#{p.id}][role_name]"}
                value={p.role_name}
                placeholder="Role (e.g. Cop)"
                class={input_class()}
              />
            </div>
            <textarea
              name={"roles[#{p.id}][pm]"}
              rows="2"
              placeholder="Role PM (optional) — shown only to this player"
              class={[input_class(), "w-full"]}
            >{p.role_pm_body}</textarea>
          </div>
          <div class="flex gap-2">
            <button type="submit" class={btn_secondary()}>Save roles</button>
            <button type="submit" phx-click="start" class={btn_primary()}>Start game</button>
          </div>
        </form>
      <% end %>
    </div>
    """
  end

  # ---- day ------------------------------------------------------------------

  defp render_body(%{game: %{status: :day}} = assigns) do
    ~H"""
    <div class="space-y-6">
      <.thread_links game={@game} my_player={@my_player} />

      <div class="rounded-lg border border-[color:var(--border)] bg-[color:var(--surface-1)] p-4">
        <div class="flex items-center justify-between mb-2">
          <h2 class="font-semibold text-[color:var(--text)]">Vote to lynch</h2>
          <span class="text-xs text-[color:var(--text-muted)]">
            Hammer at {@vote_counts.hammer} · {@vote_counts.total} votes cast
          </span>
        </div>

        <ul class="space-y-2">
          <li :for={p <- living(@game.players)} class="flex items-center justify-between">
            <span class="text-[color:var(--text)]">
              {user_name(p.user)}
              <span class="text-[color:var(--text-muted)]">
                — {Map.get(@vote_counts.tallies, p.id, 0)}
              </span>
            </span>
            <button
              :if={can_vote?(assigns)}
              phx-click="cast_vote"
              phx-value-target={p.id}
              class={if @my_vote == p.id, do: btn_primary(), else: btn_secondary()}
            >
              {if @my_vote == p.id, do: "Voted", else: "Vote"}
            </button>
          </li>
        </ul>

        <div
          :if={can_vote?(assigns)}
          class="flex gap-2 mt-3 pt-3 border-t border-[color:var(--border)]"
        >
          <button
            phx-click="cast_vote"
            phx-value-target="no_lynch"
            class={if @my_vote == :no_lynch, do: btn_primary(), else: btn_secondary()}
          >
            No lynch ({Map.get(@vote_counts.tallies, :no_lynch, 0)})
          </button>
          <button :if={@my_vote} phx-click="retract_vote" class={btn_secondary()}>Unvote</button>
        </div>
        <p :if={!can_vote?(assigns)} class="text-sm text-[color:var(--text-muted)]">
          {if @my_player, do: "You are out of the game.", else: "Spectators can't vote."}
        </p>
      </div>

      <.host_panel :if={@is_host} game={@game} night_actions={@night_actions} />
    </div>
    """
  end

  # ---- night ----------------------------------------------------------------

  defp render_body(%{game: %{status: :night}} = assigns) do
    ~H"""
    <div class="space-y-6">
      <.thread_links game={@game} my_player={@my_player} />

      <div
        :if={@my_player && @my_player.is_alive}
        class="rounded-lg border border-[color:var(--border)] bg-[color:var(--surface-1)] p-4"
      >
        <h2 class="font-semibold text-[color:var(--text)] mb-2">Submit a night action</h2>
        <p class="text-xs text-[color:var(--text-muted)] mb-3">
          If your role acts at night, submit it here. The moderator resolves it.
        </p>
        <form phx-submit="submit_night_action" class="flex flex-col sm:flex-row gap-2">
          <input
            type="text"
            name="action_kind"
            placeholder="Action (e.g. investigate)"
            required
            class={input_class()}
          />
          <select name="target" class={input_class()}>
            <option value="none">No target</option>
            <option :for={p <- living(@game.players)} value={p.id}>{user_name(p.user)}</option>
          </select>
          <button type="submit" class={btn_primary()}>Submit</button>
        </form>
      </div>

      <.host_panel :if={@is_host} game={@game} night_actions={@night_actions} />
    </div>
    """
  end

  # ---- finished -------------------------------------------------------------

  defp render_body(%{game: %{status: :finished}} = assigns) do
    ~H"""
    <div class="rounded-lg border border-[color:var(--border)] bg-[color:var(--surface-1)] p-4">
      <h2 class="font-semibold text-[color:var(--text)] mb-3">Final roles</h2>
      <ul class="divide-y divide-[color:var(--border)]">
        <li :for={p <- @game.players} class="flex items-center justify-between py-2">
          <span class="text-[color:var(--text)]">{user_name(p.user)}</span>
          <span class="text-sm text-[color:var(--text-muted)]">
            {p.role_name || "—"} ({p.alignment}){if !p.is_alive, do: " · dead"}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  # ---- shared function components -------------------------------------------

  attr :game, :map, required: true
  attr :my_player, :map, default: nil

  defp thread_links(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <.link
        :if={@game.day_thread_conversation_id}
        navigate={~p"/messages/#{@game.day_thread_conversation_id}"}
        class={btn_secondary()}
      >
        Open Town Square
      </.link>
      <.link
        :if={@my_player && @my_player.alignment == :mafia && @game.mafia_chat_conversation_id}
        navigate={~p"/messages/#{@game.mafia_chat_conversation_id}"}
        class={btn_secondary()}
      >
        Open Mafia chat
      </.link>
    </div>
    """
  end

  attr :game, :map, required: true
  attr :night_actions, :list, default: []

  defp host_panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-amber-500/40 bg-[color:var(--surface-1)] p-4 space-y-4">
      <h2 class="font-semibold text-amber-400">Moderator controls</h2>

      <div :if={@game.status == :night}>
        <h3 class="text-sm font-medium text-[color:var(--text)] mb-2">Night actions submitted</h3>
        <p :if={@night_actions == []} class="text-sm text-[color:var(--text-muted)]">None yet.</p>
        <ul class="space-y-2">
          <li :for={a <- @night_actions} class="rounded-md border border-[color:var(--border)] p-2">
            <div class="text-sm text-[color:var(--text)]">
              {user_name(if match?(%{user: _}, a.actor_player), do: a.actor_player.user)}:
              <b>{a.action_kind}</b>
              {if match?(%{user: _}, a.target_player), do: "→ #{user_name(a.target_player.user)}"}
              {if a.resolved, do: "· resolved"}
            </div>
            <form :if={!a.resolved} phx-submit="resolve_night_action" class="flex gap-2 mt-1">
              <input type="hidden" name="action_id" value={a.id} />
              <input type="text" name="result" placeholder="Result / outcome" class={input_class()} />
              <button type="submit" class={btn_secondary()}>Record</button>
            </form>
          </li>
        </ul>
        <button phx-click="open_next_day" class={[btn_primary(), "mt-3"]}>Open next day</button>
      </div>

      <div>
        <h3 class="text-sm font-medium text-[color:var(--text)] mb-2">Eliminate a player</h3>
        <ul class="space-y-1">
          <li :for={p <- living(@game.players)} class="flex items-center justify-between text-sm">
            <span class="text-[color:var(--text)]">{user_name(p.user)} ({p.alignment})</span>
            <span class="flex gap-2">
              <button
                phx-click="eliminate"
                phx-value-player_id={p.id}
                phx-value-reason="night"
                class="text-[color:var(--text-muted)] hover:text-red-400"
              >
                night kill
              </button>
              <button
                phx-click="eliminate"
                phx-value-player_id={p.id}
                phx-value-reason="modkill"
                class="text-[color:var(--text-muted)] hover:text-red-400"
              >
                modkill
              </button>
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # ---- tiny style + guard helpers -------------------------------------------

  defp can_vote?(%{my_player: %{is_alive: true}}), do: true
  defp can_vote?(_), do: false

  defp btn_primary,
    do:
      "rounded-md bg-[color:var(--color-primary)] px-3 py-1.5 text-sm font-medium text-[color:var(--color-on-primary)]"

  defp btn_secondary,
    do:
      "rounded-md border border-[color:var(--border)] px-3 py-1.5 text-sm text-[color:var(--text)] hover:bg-[color:var(--surface-2)]"

  defp input_class,
    do:
      "rounded-md border border-[color:var(--border)] bg-[color:var(--surface-2)] px-3 py-2 text-sm text-[color:var(--text)]"
end
