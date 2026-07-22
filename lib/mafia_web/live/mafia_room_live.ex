defmodule MafiaWeb.MafiaRoomLive do
  @moduledoc """
  A single Mafia game. Public (spectators can watch); actions are gated by login,
  membership, and — for moderation — being the host. The host panel is folded in
  here rather than a separate dashboard.
  """
  use MafiaWeb, :live_view

  alias Mafia.{Chat, GameRules, Games}
  import MafiaWeb.GameComponents

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

  def handle_event("cast_vote", %{"ballot" => ballot, "target" => target}, socket) do
    target_id = if target == "no_lynch", do: nil, else: target

    handle_result(
      Games.cast_ballot(
        socket.assigns.game,
        socket.assigns.current_user.id,
        ballot,
        target_id
      ),
      socket
    )
  end

  def handle_event("retract_vote", %{"ballot" => ballot}, socket) do
    handle_result(
      Games.retract_ballot(socket.assigns.game, socket.assigns.current_user.id, ballot),
      socket
    )
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

  def handle_event("moderate_player", %{"player" => attrs}, socket) do
    overrides =
      attrs
      |> Map.get("capability_overrides", %{})
      |> Map.new(fn {capability, value} ->
        parsed =
          case value do
            "allow" -> true
            "deny" -> false
            _ -> nil
          end

        {capability, parsed}
      end)
      |> Enum.reject(fn {_capability, value} -> is_nil(value) end)
      |> Map.new()

    player_attrs = %{
      status: attrs["status"],
      alignment: blank_to_nil(attrs["alignment"]),
      role_name: blank_to_nil(attrs["role_name"]),
      tags: parse_tags(attrs["tags"]),
      capability_overrides: overrides
    }

    handle_result(
      Games.moderate_player(
        socket.assigns.game,
        attrs["id"],
        socket.assigns.current_user.id,
        player_attrs
      ),
      socket
    )
  end

  def handle_event("declare_winner", %{"winner" => winner}, socket) do
    handle_result(
      Games.declare_winner(
        socket.assigns.game,
        blank_to_nil(winner),
        socket.assigns.current_user.id
      ),
      socket
    )
  end

  def handle_event("create_side_chat", %{"chat" => attrs}, socket) do
    member_ids = Map.get(attrs, "members", [])

    case Games.create_side_chat(
           socket.assigns.game,
           socket.assigns.current_user.id,
           member_ids,
           blank_to_nil(attrs["title"])
         ) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Private chat opened.")
         |> push_navigate(to: ~p"/messages/#{conversation.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize(reason))}
    end
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
        rules = GameRules.normalize(game.ruleset)

        game_conversations =
          if user do
            user.id
            |> Chat.list_user_conversations()
            |> Enum.filter(&(Map.get(&1.metadata || %{}, "mafia_game_id") == game.id))
          else
            []
          end

        ballots =
          rules
          |> GameRules.ballots(game.status)
          |> Enum.map(fn ballot ->
            %{
              config: ballot,
              totals: Games.visible_ballot_totals(game, ballot["key"], user && user.id),
              choice: user && Games.ballot_choice(game, user.id, ballot["key"])
            }
          end)

        socket
        |> assign(:game, game)
        |> assign(:rules, rules)
        |> assign(:page_title, game.title || "Mafia")
        |> assign(:is_host, !!is_host)
        |> assign(:my_player, my_player)
        |> assign(:game_conversations, game_conversations)
        |> assign(:ballots, ballots)
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

  defp parse_alignment(value), do: blank_to_nil(value)

  defp parse_reason("night"), do: :night
  defp parse_reason(_), do: :modkill

  defp user_name(%Ash.NotLoaded{}), do: "Player"
  defp user_name(nil), do: "Player"
  # No email fallback — usernames are required (non-null), and an email must never
  # render as a display name to other players in the room.
  defp user_name(user), do: Map.get(user, :username) || "Player"

  defp active(players), do: Enum.filter(players, &(GameRules.player_status(&1) == "active"))

  defp parse_tags(nil), do: []

  defp parse_tags(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(50)
  end

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

      <.game_nav
        game={@game}
        current={:overview}
        show_notes={!!@my_player}
        show_settings={@is_host}
      />
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
          Current rulebook
        </summary>
        <div class="mt-3 space-y-3 text-sm leading-6 text-[color:var(--text-muted)]">
          <p>{GameRules.summary(@rules)}</p>
          <p :if={@rules["description"] != ""} class="whitespace-pre-wrap">
            {@rules["description"]}
          </p>
          <.link navigate={~p"/mafia/#{@game.id}/rules"} class="btn btn-secondary text-sm">
            <.icon name="hero-document-text" class="size-4" /> Read the full rules
          </.link>
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
                <input
                  type="text"
                  name={"roles[#{p.id}][alignment]"}
                  value={p.alignment}
                  placeholder="Faction (for example, town)"
                  required
                  class={input_class()}
                />
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
              <span class="sr-only">Private role message for {user_name(p.user)}</span> <textarea
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
      <.thread_links conversations={@game_conversations} />
      <.roster_overview game={@game} my_player={@my_player} is_host={@is_host} />
      <.side_chat_creator game={@game} my_player={@my_player} rules={@rules} />

      <div :if={@ballots == []} class="empty-state">
        <div>
          <span class="empty-state-icon" aria-hidden="true">
            <.icon name="hero-check-badge" class="size-6" />
          </span>
          <p class="font-semibold text-[color:var(--text)]">No ballot is open this phase.</p>
        </div>
      </div>

      <.ballot_board
        :for={ballot <- @ballots}
        game={@game}
        ballot={ballot}
        my_player={@my_player}
        is_host={@is_host}
      />

      <.host_panel :if={@is_host} game={@game} night_actions={@night_actions} />
    </div>
    """
  end

  # ---- night ----------------------------------------------------------------

  defp render_body(%{game: %{status: :night}} = assigns) do
    ~H"""
    <div class="space-y-6">
      <.thread_links conversations={@game_conversations} />
      <.roster_overview game={@game} my_player={@my_player} is_host={@is_host} />
      <.side_chat_creator game={@game} my_player={@my_player} rules={@rules} />

      <.ballot_board
        :for={ballot <- @ballots}
        game={@game}
        ballot={ballot}
        my_player={@my_player}
        is_host={@is_host}
      />

      <div
        :if={can_act?(@game, @my_player)}
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

              <option :for={p <- action_targets(@game)} value={p.id}>{user_name(p.user)}</option>
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
            {p.role_name || "—"} ({p.alignment || "no faction"}) · {player_status_label(p)}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  # ---- shared function components -------------------------------------------

  attr :game, :map, required: true
  attr :my_player, :map, default: nil
  attr :is_host, :boolean, default: false

  defp roster_overview(assigns) do
    ~H"""
    <details class="panel">
      <summary class="flex cursor-pointer items-center justify-between gap-3">
        <span class="font-semibold text-[color:var(--text)]">Player roster</span>
        <span class="status-chip">{length(active(@game.players))} active</span>
      </summary>
      <ul class="mt-4 divide-y divide-[color:var(--border)]">
        <li
          :for={player <- @game.players}
          class="flex min-h-14 flex-wrap items-center justify-between gap-3 py-2"
        >
          <span class="min-w-0">
            <span class="block truncate font-semibold text-[color:var(--text)]">
              {user_name(player.user)}
            </span>
            <span
              :if={
                (@is_host || (@my_player && @my_player.id == player.id)) && (player.tags || []) != []
              }
              class="mt-1 block text-xs text-[color:var(--text-muted)]"
            >
              {Enum.join(player.tags, " · ")}
            </span>
          </span>
          <span class="flex flex-wrap items-center justify-end gap-2">
            <span
              :if={@is_host || @game.status == :finished}
              class="text-xs text-[color:var(--text-muted)]"
            >
              {player.alignment || "No faction"}
            </span>
            <span class="status-chip">{player_status_label(player)}</span>
          </span>
        </li>
      </ul>
    </details>
    """
  end

  attr :game, :map, required: true
  attr :my_player, :map, default: nil
  attr :rules, :map, required: true

  defp side_chat_creator(assigns) do
    ~H"""
    <details :if={can_private_chat?(@game, @my_player, @rules)} class="panel">
      <summary class="flex cursor-pointer items-center justify-between gap-3">
        <span class="font-semibold text-[color:var(--text)]">Open a private chat</span>
        <span class="status-chip">Up to {@rules["private_chat_participant_cap"]} players</span>
      </summary>
      <p class="mt-3 text-sm leading-6 text-[color:var(--text-muted)]">
        This chat belongs to the current phase. Your status and the game's chat cap still apply.
      </p>
      <form phx-submit="create_side_chat" class="mt-4 space-y-4">
        <.input
          name="chat[title]"
          label="Chat title"
          maxlength="120"
          placeholder="Night coalition"
        />
        <fieldset>
          <legend class="text-sm font-semibold text-[color:var(--text)]">Invite players</legend>
          <div class="mt-2 grid gap-1 sm:grid-cols-2">
            <label
              :for={player <- private_chat_participants(@game, @my_player)}
              class="flex min-h-11 items-center gap-2 rounded-md px-2 text-sm"
            >
              <input
                type="checkbox"
                name="chat[members][]"
                value={player.user_id}
                class="size-5 rounded accent-[var(--color-primary)]"
              />
              <span class="truncate">{user_name(player.user)}</span>
            </label>
          </div>
        </fieldset>
        <button type="submit" class={btn_secondary()} phx-disable-with="Opening…">
          <.icon name="hero-lock-closed" class="size-4" /> Create private chat
        </button>
      </form>
    </details>
    """
  end

  attr :conversations, :list, required: true

  defp thread_links(assigns) do
    ~H"""
    <nav :if={@conversations != []} class="flex flex-wrap gap-2" aria-label="Game conversations">
      <.link
        :for={conversation <- @conversations}
        navigate={~p"/messages/#{conversation.id}"}
        class={btn_secondary()}
      >
        <.icon name={conversation_icon(conversation)} class="size-4" />
        {conversation.title || "Game chat"}
      </.link>
    </nav>
    """
  end

  attr :game, :map, required: true
  attr :ballot, :map, required: true
  attr :my_player, :map, default: nil
  attr :is_host, :boolean, default: false

  defp ballot_board(assigns) do
    ~H"""
    <section id={"ballot-#{@ballot.config["key"]}"} class="panel">
      <div class="mb-4 flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p class="eyebrow">{@ballot.config["phase"]} ballot</p>
          <h2 class="section-heading mt-2">{@ballot.config["title"]}</h2>
          <p
            :if={@ballot.config["description"] != ""}
            class="mt-2 max-w-2xl text-sm leading-6 text-[color:var(--text-muted)]"
          >
            {@ballot.config["description"]}
          </p>
        </div>
        <span class="status-chip self-start" aria-live="polite">
          {ballot_status(@ballot, @is_host)}
        </span>
      </div>

      <ul class="divide-y divide-[color:var(--border)]">
        <li
          :for={player <- ballot_candidates(@game, @ballot.config)}
          class="flex min-h-16 items-center justify-between gap-3 py-2"
        >
          <span class="flex min-w-0 items-center gap-3 text-[color:var(--text)]">
            <span class="phase-icon size-9 shrink-0" aria-hidden="true">
              <.icon name="hero-user" class="size-4" />
            </span>
            <span class="min-w-0">
              <span class="block truncate font-semibold">{user_name(player.user)}</span>
              <span
                :if={show_candidate_totals?(@ballot.config, @is_host)}
                class="mono text-xs text-[color:var(--text-muted)]"
              >
                {pluralize(Map.get(@ballot.totals.tallies, player.id, 0), "vote")}
              </span>
              <span
                :if={
                  show_voter_names?(@ballot.config, @is_host) &&
                    Map.get(@ballot.totals[:voters_by_target] || %{}, player.id, []) != []
                }
                class="mt-0.5 block text-xs text-[color:var(--text-muted)]"
              >
                {Enum.join(Map.get(@ballot.totals.voters_by_target, player.id, []), ", ")}
              </span>
            </span>
          </span>
          <button
            :if={can_vote_on?(@game, @my_player, @ballot.config)}
            type="button"
            phx-click="cast_vote"
            phx-value-ballot={@ballot.config["key"]}
            phx-value-target={player.id}
            class={if @ballot.choice == player.id, do: btn_primary(), else: btn_secondary()}
            aria-pressed={@ballot.choice == player.id}
            phx-disable-with="Voting…"
          >
            <.icon name="hero-hand-raised" class="size-4" />
            {if @ballot.choice == player.id, do: "Voted", else: "Vote"}
          </button>
        </li>
      </ul>

      <div
        :if={can_vote_on?(@game, @my_player, @ballot.config)}
        class="mt-3 flex flex-wrap gap-2 border-t border-[color:var(--border)] pt-4"
      >
        <button
          :if={@ballot.config["allow_no_result"]}
          type="button"
          phx-click="cast_vote"
          phx-value-ballot={@ballot.config["key"]}
          phx-value-target="no_lynch"
          class={if @ballot.choice == :no_lynch, do: btn_primary(), else: btn_secondary()}
          aria-pressed={@ballot.choice == :no_lynch}
        >
          {@ballot.config["no_result_label"]}{no_result_count(@ballot, @is_host)}
        </button>
        <button
          :if={@ballot.choice}
          type="button"
          phx-click="retract_vote"
          phx-value-ballot={@ballot.config["key"]}
          class={btn_secondary()}
        >
          Withdraw ballot
        </button>
      </div>

      <p
        :if={!can_vote_on?(@game, @my_player, @ballot.config)}
        class="mt-3 text-sm text-[color:var(--text-muted)]"
      >
        {ballot_ineligible_text(@my_player, @ballot.config)}
      </p>
      <p
        :if={@ballot.config["visibility"] == "secret" && @ballot.choice && !@is_host}
        class="mt-3 text-sm font-semibold text-[color:var(--link)]"
      >
        Your ballot is recorded. Totals are hidden.
      </p>
      <p
        :if={
          show_voter_names?(@ballot.config, @is_host) &&
            (@ballot.totals[:unvoted] || []) != []
        }
        class="mt-3 text-xs leading-5 text-[color:var(--text-muted)]"
      >
        <span class="font-semibold text-[color:var(--text-soft)]">No ballot yet:</span>
        {Enum.join(@ballot.totals.unvoted, ", ")}
      </p>
    </section>
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
              <b>{a.action_kind}</b> {if match?(%{user: _}, a.target_player),
                do: "→ #{user_name(a.target_player.user)}"} {if a.resolved, do: "· resolved"}
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
        <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h3 class="text-sm font-semibold text-[color:var(--text)]">Player states</h3>
            <p class="mt-1 text-xs leading-5 text-[color:var(--text-muted)]">
              Status sets the default permissions. Per-player overrides handle exceptions.
            </p>
          </div>
          <.link navigate={~p"/mafia/#{@game.id}/settings"} class="btn btn-secondary text-xs">
            <.icon name="hero-adjustments-horizontal" class="size-4" /> Rule settings
          </.link>
        </div>

        <div class="mt-3 space-y-2">
          <details
            :for={player <- @game.players}
            class="rounded-md border border-[color:var(--border)] bg-black/10 p-3"
          >
            <summary class="flex cursor-pointer items-center justify-between gap-3">
              <span class="truncate font-semibold text-[color:var(--text)]">
                {user_name(player.user)}
              </span>
              <span class="status-chip shrink-0">{player_status_label(player)}</span>
            </summary>

            <form phx-submit="moderate_player" class="mt-4 space-y-4">
              <input type="hidden" name="player[id]" value={player.id} />
              <div class="grid gap-3 sm:grid-cols-2">
                <.input
                  type="select"
                  name="player[status]"
                  label="Status"
                  value={GameRules.player_status(player)}
                  options={[
                    {"Active", "active"},
                    {"Eliminated", "dead"},
                    {"Removed", "removed"},
                    {"Spectator", "spectator"}
                  ]}
                />
                <.input
                  name="player[alignment]"
                  label="Faction"
                  value={player.alignment}
                  maxlength="100"
                />
                <.input
                  name="player[role_name]"
                  label="Role"
                  value={player.role_name}
                  maxlength="100"
                />
                <.input
                  name="player[tags]"
                  label="Tags"
                  value={Enum.join(player.tags || [], ", ")}
                  placeholder="infected, president, immune"
                />
              </div>

              <fieldset>
                <legend class="text-sm font-semibold text-[color:var(--text)]">
                  Capability exceptions
                </legend>
                <div class="mt-2 grid gap-2 sm:grid-cols-2">
                  <.input
                    :for={capability <- moderator_capabilities()}
                    type="select"
                    name={"player[capability_overrides][#{capability}]"}
                    label={capability_label(capability)}
                    value={override_value(player.capability_overrides, capability)}
                    options={[
                      {"Use status default", "inherit"},
                      {"Always allow", "allow"},
                      {"Always deny", "deny"}
                    ]}
                  />
                </div>
              </fieldset>

              <button type="submit" class={btn_secondary()} phx-disable-with="Saving…">
                Save player state
              </button>
            </form>
          </details>
        </div>
      </div>

      <div class="border-t border-[color:var(--border)] pt-4">
        <h3 class="mb-2 text-sm font-semibold text-[color:var(--text)]">Eliminate a player</h3>
        <ul class="divide-y divide-[color:var(--border)]">
          <li
            :for={p <- active(@game.players)}
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

      <form
        :if={@game.status != :finished}
        phx-submit="declare_winner"
        class="border-t border-[color:var(--border)] pt-4"
      >
        <h3 class="text-sm font-semibold text-[color:var(--text)]">Close the case</h3>
        <p class="mt-1 text-xs leading-5 text-[color:var(--text-muted)]">
          Declare any faction or individual winner. This is the override for custom win conditions.
        </p>
        <div class="mt-3 flex flex-col gap-2 sm:flex-row">
          <label for="winner-label" class="sr-only">Winning faction or player</label>
          <input
            id="winner-label"
            type="text"
            name="winner"
            required
            maxlength="100"
            placeholder="Winning faction or player"
            class={[input_class(), "min-w-0 flex-1"]}
          />
          <button
            type="submit"
            data-confirm="End this game and publish the winner?"
            class={btn_primary()}
          >
            <.icon name="hero-scale" class="size-4" /> Declare winner
          </button>
        </div>
      </form>

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

  defp can_vote_on?(_game, nil, _ballot), do: false

  defp can_vote_on?(game, player, ballot) do
    GameRules.player_status(player) in ballot["eligible_statuses"] and
      Games.player_can?(game, player, "vote")
  end

  defp can_act?(_game, nil), do: false
  defp can_act?(game, player), do: Games.player_can?(game, player, "act")

  defp ballot_candidates(game, ballot) do
    Enum.filter(game.players, fn player ->
      GameRules.player_status(player) in ballot["candidate_statuses"] and
        Games.player_can?(game, player, "candidate") and
        Games.player_can?(game, player, "targetable")
    end)
  end

  defp action_targets(game) do
    Enum.filter(game.players, &Games.player_can?(game, &1, "targetable"))
  end

  defp can_private_chat?(_game, nil, _rules), do: false

  defp can_private_chat?(game, player, rules) do
    GameRules.private_chat_allowed?(rules, game.status) and
      Games.player_can?(game, player, "private_chat") and
      rules["night_conversation_cap"] > 0
  end

  defp private_chat_participants(game, my_player) do
    Enum.filter(game.players, fn player ->
      player.id != my_player.id and Games.player_can?(game, player, "private_chat")
    end)
  end

  defp conversation_icon(conversation) do
    case Map.get(conversation.metadata || %{}, "channel") do
      "day_thread" -> "hero-chat-bubble-oval-left-ellipsis"
      "faction" -> "hero-eye-slash"
      "side_chat" -> "hero-lock-closed"
      _ -> "hero-chat-bubble-left-right"
    end
  end

  defp ballot_status(%{config: ballot, totals: totals}, is_host) do
    cond do
      is_host or ballot["visibility"] == "live" ->
        base = pluralize(totals.total, "ballot")
        if ballot["method"] == "majority", do: "#{base} · hammer #{totals.hammer}", else: base

      ballot["visibility"] == "totals" ->
        pluralize(totals.total, "ballot") <> " cast"

      true ->
        "Secret ballot"
    end
  end

  defp show_candidate_totals?(ballot, is_host),
    do: is_host or ballot["visibility"] == "live"

  defp show_voter_names?(ballot, is_host),
    do: is_host or (ballot["visibility"] == "live" and ballot["show_voters"])

  defp no_result_count(%{config: ballot, totals: totals}, is_host) do
    if show_candidate_totals?(ballot, is_host),
      do: " (#{Map.get(totals.tallies, :no_lynch, 0)})",
      else: ""
  end

  defp ballot_ineligible_text(nil, _ballot),
    do: "Spectators can follow this ballot but cannot vote."

  defp ballot_ineligible_text(player, ballot) do
    status = GameRules.player_status(player)

    if status in ballot["eligible_statuses"],
      do: "Your current permissions do not allow voting.",
      else:
        "Players with the #{player_status_label(player)} status are not eligible for this ballot."
  end

  defp pluralize(1, noun), do: "1 #{noun}"
  defp pluralize(count, noun), do: "#{count} #{noun}s"

  defp player_status_label(player) when is_map(player) do
    case GameRules.player_status(player) do
      "active" -> "Active"
      "dead" -> "Eliminated"
      "removed" -> "Removed"
      "spectator" -> "Spectator"
      status -> String.capitalize(status)
    end
  end

  defp moderator_capabilities,
    do: ~w(post_public vote act private_chat react targetable candidate)

  defp capability_label("post_public"), do: "Post publicly"
  defp capability_label("vote"), do: "Cast ballots"
  defp capability_label("act"), do: "Submit actions"
  defp capability_label("private_chat"), do: "Use private chats"
  defp capability_label("react"), do: "React to posts"
  defp capability_label("targetable"), do: "May be targeted"
  defp capability_label("candidate"), do: "May be a candidate"
  defp capability_label(capability), do: String.replace(capability, "_", " ")

  defp override_value(overrides, capability) do
    case Map.get(overrides || %{}, capability) do
      true -> "allow"
      false -> "deny"
      _ -> "inherit"
    end
  end

  defp btn_primary,
    do: "btn btn-primary text-sm"

  defp btn_secondary,
    do: "btn btn-secondary text-sm"

  defp input_class, do: "input text-sm"
end
