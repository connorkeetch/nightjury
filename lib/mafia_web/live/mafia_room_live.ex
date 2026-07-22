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
    <div class="mx-auto max-w-5xl space-y-6">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div class="min-w-0">
          <p class="eyebrow">Case file</p>
          <h1 class="page-heading mt-2 truncate">{@game.title || "Untitled game"}</h1>
        </div>
        <.link navigate={~p"/mafia"} class="btn btn-quiet self-start sm:self-auto">
          <.icon name="hero-arrow-left" class="size-4" /> All games
        </.link>
      </header>

      <section class="phase-banner" aria-label="Current game phase">
        <span class="phase-icon" aria-hidden="true">
          <.icon name={phase_icon(@game.status)} class="size-5" />
        </span>
        <div class="min-w-0">
          <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-[color:var(--text-muted)]">
            Current phase
          </p>
          <h2 class="section-heading mt-0.5">{phase_label(@game)}</h2>
        </div>
        <p class="mono text-xs leading-5 text-[color:var(--text-muted)] sm:text-right">
          {status_line(assigns)}
        </p>
      </section>

      <%= if @my_player && @my_player.role_name do %>
        <section class="panel role-card">
          <div class="flex items-start gap-3">
            <span class="phase-icon shrink-0 border-[color:rgba(201,104,82,0.35)] text-[color:var(--wax)]">
              <.icon name="hero-identification" class="size-5" />
            </span>
            <div class="min-w-0">
              <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-[color:var(--text-muted)]">
                Your private role
              </p>
              <h2 class="mt-1 font-[family-name:var(--font-display)] text-2xl font-bold text-[color:var(--text)]">
                {@my_player.role_name}
              </h2>
              <span class="status-chip status-chip-wax mt-2">{@my_player.alignment}</span>
            </div>
          </div>
          <p
            :if={@my_player.role_pm_body}
            class="mt-4 whitespace-pre-wrap border-t border-[color:var(--border)] pt-4 text-sm leading-6 text-[color:var(--text-soft)]"
          >
            {@my_player.role_pm_body}
          </p>
        </section>
      <% end %>

      {render_body(assigns)}
    </div>
    """
  end

  defp status_line(%{game: %{status: :setup}}),
    do: "Waiting for the moderator"

  defp status_line(%{game: %{status: :finished} = g}),
    do: "The #{g.winner_faction} win"

  defp status_line(%{game: g} = assigns) do
    left = time_left(g.phase_ends_at, assigns[:now] || DateTime.utc_now())

    "#{left} · closes #{deadline_text(g.phase_ends_at)}"
  end

  defp phase_label(%{status: :setup}), do: "Room setup"
  defp phase_label(%{status: :finished}), do: "Final verdict"

  defp phase_label(%{status: status} = game),
    do: "#{String.capitalize(to_string(status))} #{day_number(game)}"

  defp phase_icon(:setup), do: "hero-key"
  defp phase_icon(:day), do: "hero-sun"
  defp phase_icon(:night), do: "hero-moon"
  defp phase_icon(:finished), do: "hero-scale"

  # ---- setup ----------------------------------------------------------------

  defp render_body(%{game: %{status: :setup}} = assigns) do
    ~H"""
    <div class="space-y-6">
      <details class="panel">
        <summary class="cursor-pointer font-semibold text-[color:var(--text)]">
          How Night Jury works
        </summary>
        <div class="mt-3 space-y-2 text-sm leading-6 text-[color:var(--text-muted)]">
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

      <section class="panel">
        <div class="mb-3 flex items-center justify-between gap-3">
          <h2 class="section-heading">Players</h2>
          <span class="status-chip">{length(@game.players)} seated</span>
        </div>
        <ul class="divide-y divide-[color:var(--border)]">
          <li :for={p <- @game.players} class="flex min-h-12 items-center justify-between gap-3 py-2">
            <span class="flex min-w-0 items-center gap-2 text-[color:var(--text)]">
              <.icon name="hero-user-circle" class="size-5 shrink-0 text-[color:var(--text-muted)]" />
              <span class="truncate">{user_name(p.user)}</span>
            </span>
            <button
              :if={@is_host}
              type="button"
              phx-click="kick"
              phx-value-player_id={p.id}
              class="btn btn-quiet shrink-0 text-xs hover:text-[color:var(--color-danger-text)]"
            >
              Remove
            </button>
          </li>
        </ul>
        <p :if={@game.players == []} class="py-4 text-sm text-[color:var(--text-muted)]">
          No players on file. The moderator is accepting names.
        </p>

        <div :if={@current_user && !@is_host} class="mt-3">
          <%= cond do %>
            <% @my_player -> %>
              <button type="button" phx-click="leave" class={btn_secondary()}>Leave game</button>
            <% Games.lobby_type(@game) == "open" -> %>
              <button type="button" phx-click="join" class={btn_primary()}>Join game</button>
            <% true -> %>
              <span class="text-sm text-[color:var(--text-muted)]">
                Invite only — the moderator adds players.
              </span>
          <% end %>
        </div>
      </section>

      <section :if={@is_host} class="panel">
        <h2 class="section-heading">Add a player</h2>
        <p class="mt-1 text-sm text-[color:var(--text-muted)]">
          Seat someone directly using their username or email.
        </p>
        <form phx-submit="add_player" class="mt-4 flex flex-col gap-2 sm:flex-row">
          <label for="player-name" class="sr-only">Username or email</label>
          <input
            id="player-name"
            type="text"
            name="name"
            placeholder="Username or email"
            required
            class={[input_class(), "min-w-0 flex-1"]}
          />
          <button type="submit" class={btn_secondary()} phx-disable-with="Adding…">
            <.icon name="hero-user-plus" class="size-4" /> Add player
          </button>
        </form>
      </section>

      <%= if @is_host do %>
        <form
          phx-submit="assign_roles"
          class="panel space-y-5"
        >
          <div>
            <h2 class="section-heading">Prepare the cast</h2>
            <p class="mt-1 text-sm leading-6 text-[color:var(--text-muted)]">
              Every player needs an alignment. Role names and private instructions are yours to write.
            </p>
          </div>
          <div
            :for={p <- @game.players}
            class="space-y-2 border-b border-[color:var(--border)] pb-4 last:border-b-0"
          >
            <p class="text-sm font-semibold text-[color:var(--text)]">{user_name(p.user)}</p>
            <div class="grid grid-cols-1 gap-2 sm:grid-cols-[9rem_1fr]">
              <label>
                <span class="sr-only">Alignment for {user_name(p.user)}</span>
                <select name={"roles[#{p.id}][alignment]"} class={input_class()}>
                  <option value="town" selected={p.alignment == :town}>Town</option>
                  <option value="mafia" selected={p.alignment == :mafia}>Mafia</option>
                </select>
              </label>
              <label>
                <span class="sr-only">Role for {user_name(p.user)}</span>
                <input
                  type="text"
                  name={"roles[#{p.id}][role_name]"}
                  value={p.role_name}
                  placeholder="Role (for example, Detective)"
                  class={input_class()}
                />
              </label>
            </div>
            <label class="block">
              <span class="sr-only">Private role message for {user_name(p.user)}</span>
              <textarea
                name={"roles[#{p.id}][pm]"}
                rows="2"
                placeholder="Role PM (optional) — shown only to this player"
                class={[input_class(), "w-full"]}
              >{p.role_pm_body}</textarea>
            </label>
          </div>
          <div class="flex flex-col gap-3 border-t border-[color:var(--border)] pt-4 sm:flex-row sm:items-center">
            <button type="submit" class={btn_secondary()} phx-disable-with="Saving…">
              Save roles
            </button>
            <button
              type="button"
              phx-click="start"
              class={btn_primary()}
              phx-disable-with="Starting…"
            >
              <.icon name="hero-play" class="size-4" /> Start game
            </button>
            <p class="text-xs text-[color:var(--text-muted)] sm:ml-auto">
              Save any role edits before starting.
            </p>
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

      <section class="panel">
        <div class="mb-4 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <p class="eyebrow">Public record</p>
            <h2 class="section-heading mt-2">Cast your vote</h2>
          </div>
          <span class="status-chip self-start sm:self-auto">
            Hammer at {@vote_counts.hammer} · {@vote_counts.total} votes cast
          </span>
        </div>

        <ul class="divide-y divide-[color:var(--border)]">
          <li
            :for={p <- living(@game.players)}
            class="flex min-h-16 items-center justify-between gap-3 py-2"
          >
            <span class="flex min-w-0 items-center gap-3 text-[color:var(--text)]">
              <span class="phase-icon size-9 shrink-0" aria-hidden="true">
                <.icon name="hero-user" class="size-4" />
              </span>
              <span class="min-w-0">
                <span class="block truncate font-semibold">{user_name(p.user)}</span>
                <span class="mono text-xs text-[color:var(--text-muted)]">
                  {Map.get(@vote_counts.tallies, p.id, 0)} votes
                </span>
              </span>
            </span>
            <button
              :if={can_vote?(assigns)}
              type="button"
              phx-click="cast_vote"
              phx-value-target={p.id}
              class={if @my_vote == p.id, do: btn_primary(), else: btn_secondary()}
              aria-pressed={@my_vote == p.id}
              phx-disable-with="Voting…"
            >
              <.icon name="hero-hand-raised" class="size-4" />
              {if @my_vote == p.id, do: "Voted", else: "Vote"}
            </button>
          </li>
        </ul>

        <div
          :if={can_vote?(assigns)}
          class="mt-3 flex flex-wrap gap-2 border-t border-[color:var(--border)] pt-4"
        >
          <button
            type="button"
            phx-click="cast_vote"
            phx-value-target="no_lynch"
            class={if @my_vote == :no_lynch, do: btn_primary(), else: btn_secondary()}
            aria-pressed={@my_vote == :no_lynch}
          >
            No lynch ({Map.get(@vote_counts.tallies, :no_lynch, 0)})
          </button>
          <button :if={@my_vote} type="button" phx-click="retract_vote" class={btn_secondary()}>
            Unvote
          </button>
        </div>
        <p :if={!can_vote?(assigns)} class="mt-3 text-sm text-[color:var(--text-muted)]">
          {if @my_player, do: "You are out of the game.", else: "Spectators can't vote."}
        </p>
      </section>

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
        class="panel"
      >
        <p class="eyebrow">Private submission</p>
        <h2 class="section-heading mt-2">Submit a night action</h2>
        <p class="mb-4 mt-1 text-sm leading-6 text-[color:var(--text-muted)]">
          If your role acts at night, submit it here. The moderator resolves it.
        </p>
        <form phx-submit="submit_night_action" class="grid gap-3 sm:grid-cols-2">
          <label>
            <span class="mb-1.5 block text-sm font-semibold">Action</span>
            <input
              type="text"
              name="action_kind"
              placeholder="For example, investigate"
              required
              class={input_class()}
            />
          </label>
          <label>
            <span class="mb-1.5 block text-sm font-semibold">Target</span>
            <select name="target" class={input_class()}>
              <option value="none">No target</option>
              <option :for={p <- living(@game.players)} value={p.id}>{user_name(p.user)}</option>
            </select>
          </label>
          <button
            type="submit"
            class={[btn_primary(), "sm:col-span-2"]}
            phx-disable-with="Submitting…"
          >
            <.icon name="hero-paper-airplane" class="size-4" /> Submit privately
          </button>
        </form>
      </div>

      <.host_panel :if={@is_host} game={@game} night_actions={@night_actions} />
    </div>
    """
  end

  # ---- finished -------------------------------------------------------------

  defp render_body(%{game: %{status: :finished}} = assigns) do
    ~H"""
    <section class="panel">
      <p class="eyebrow">The record is closed</p>
      <h2 class="section-heading mb-3 mt-2">Final roles</h2>
      <ul class="divide-y divide-[color:var(--border)]">
        <li :for={p <- @game.players} class="flex min-h-14 items-center justify-between gap-4 py-2">
          <span class="font-semibold text-[color:var(--text)]">{user_name(p.user)}</span>
          <span class="text-right text-sm text-[color:var(--text-muted)]">
            {p.role_name || "—"} ({p.alignment}){if !p.is_alive, do: " · dead"}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  # ---- shared function components -------------------------------------------

  attr :game, :map, required: true
  attr :my_player, :map, default: nil

  defp thread_links(assigns) do
    ~H"""
    <nav class="flex flex-wrap gap-2" aria-label="Game conversations">
      <.link
        :if={@game.day_thread_conversation_id}
        navigate={~p"/messages/#{@game.day_thread_conversation_id}"}
        class={btn_secondary()}
      >
        <.icon name="hero-chat-bubble-oval-left-ellipsis" class="size-4" /> Town Square
      </.link>
      <.link
        :if={@my_player && @my_player.alignment == :mafia && @game.mafia_chat_conversation_id}
        navigate={~p"/messages/#{@game.mafia_chat_conversation_id}"}
        class={btn_secondary()}
      >
        <.icon name="hero-eye-slash" class="size-4" /> Mafia chat
      </.link>
    </nav>
    """
  end

  attr :game, :map, required: true
  attr :night_actions, :list, default: []

  defp host_panel(assigns) do
    ~H"""
    <section class="panel moderator-panel space-y-5">
      <div class="flex items-center gap-3">
        <span class="phase-icon shrink-0 border-[color:rgba(211,170,98,0.34)] text-[color:var(--candle)]">
          <.icon name="hero-key" class="size-5" />
        </span>
        <div>
          <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-[color:var(--candle)]">
            Private docket
          </p>
          <h2 class="section-heading">Moderator controls</h2>
        </div>
      </div>

      <div :if={@game.status == :night}>
        <h3 class="mb-2 text-sm font-semibold text-[color:var(--text)]">Night actions submitted</h3>
        <p :if={@night_actions == []} class="text-sm text-[color:var(--text-muted)]">None yet.</p>
        <ul class="space-y-2">
          <li
            :for={a <- @night_actions}
            class="rounded-md border border-[color:var(--border)] bg-black/10 p-3"
          >
            <div class="text-sm text-[color:var(--text)]">
              {user_name(if match?(%{user: _}, a.actor_player), do: a.actor_player.user)}:
              <b>{a.action_kind}</b>
              {if match?(%{user: _}, a.target_player), do: "→ #{user_name(a.target_player.user)}"}
              {if a.resolved, do: "· resolved"}
            </div>
            <form
              :if={!a.resolved}
              phx-submit="resolve_night_action"
              class="mt-3 flex flex-col gap-2 sm:flex-row"
            >
              <input type="hidden" name="action_id" value={a.id} />
              <label for={"action-result-#{a.id}"} class="sr-only">Result or outcome</label>
              <input
                id={"action-result-#{a.id}"}
                type="text"
                name="result"
                placeholder="Result or outcome"
                class={[input_class(), "min-w-0 flex-1"]}
              />
              <button type="submit" class={btn_secondary()} phx-disable-with="Recording…">
                Record
              </button>
            </form>
          </li>
        </ul>
        <button
          type="button"
          phx-click="open_next_day"
          class={[btn_primary(), "mt-3"]}
          phx-disable-with="Opening…"
        >
          <.icon name="hero-sun" class="size-4" /> Open next day
        </button>
      </div>

      <div class="border-t border-[color:var(--border)] pt-4">
        <h3 class="mb-2 text-sm font-semibold text-[color:var(--text)]">Eliminate a player</h3>
        <ul class="divide-y divide-[color:var(--border)]">
          <li
            :for={p <- living(@game.players)}
            class="flex min-h-14 flex-wrap items-center justify-between gap-2 py-2 text-sm"
          >
            <span class="text-[color:var(--text)]">
              {user_name(p.user)} <span class="text-[color:var(--text-muted)]">({p.alignment})</span>
            </span>
            <span class="flex flex-wrap gap-1">
              <button
                type="button"
                phx-click="eliminate"
                phx-value-player_id={p.id}
                phx-value-reason="night"
                class="btn btn-quiet text-xs hover:text-[color:var(--color-danger-text)]"
              >
                Night kill
              </button>
              <button
                type="button"
                phx-click="eliminate"
                phx-value-player_id={p.id}
                phx-value-reason="modkill"
                class="btn btn-quiet text-xs hover:text-[color:var(--color-danger-text)]"
              >
                Modkill
              </button>
            </span>
          </li>
        </ul>
      </div>

      <div class="flex flex-col gap-3 border-t border-[color:var(--border)] pt-4 sm:flex-row sm:items-center sm:justify-between">
        <p class="text-xs leading-5 text-[color:var(--text-muted)]">
          Deleting a game permanently removes its room and record.
        </p>
        <button
          type="button"
          phx-click="delete_game"
          data-confirm="Delete this game permanently? This can't be undone."
          class="btn btn-quiet shrink-0 text-xs hover:text-[color:var(--color-danger-text)]"
        >
          <.icon name="hero-trash" class="size-4" /> Delete game
        </button>
      </div>
    </section>
    """
  end

  # ---- tiny style + guard helpers -------------------------------------------

  defp can_vote?(%{my_player: %{is_alive: true}}), do: true
  defp can_vote?(_), do: false

  defp btn_primary,
    do: "btn btn-primary text-sm"

  defp btn_secondary,
    do: "btn btn-secondary text-sm"

  defp input_class, do: "input text-sm"
end
