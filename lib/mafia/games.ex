defmodule Mafia.Games do
  @moduledoc """
  Context for the Mafia side-game — the single entry point for game lifecycle,
  the roster, and day-phase voting.

  Design notes (see `docs/planning/mafia-side-game.md`):

  - The moderator is a neutral overseer (the `host`), never a player.
  - Conversation surfaces (day thread, mafia chat, night channels) are the
    existing `Mafia.Chat` system — this context wires them, it does not
    reimplement messaging.
  - Server-side calls run with `authorize?: false`; the resource policies guard
    the directly-exposed paths. Integrity (alive voter, open day, before the
    deadline) is enforced here, at cast time.
  """

  require Ash.Query

  alias Mafia.{Chat, Repo, WriteGate}
  alias Mafia.Games.Resources.{MafiaGame, MafiaNightAction, MafiaPlayer, MafiaVote}
  alias Mafia.Workers.MafiaPhaseWorker

  @no_lynch :no_lynch

  # ============================================================================
  # PubSub
  # ============================================================================

  @doc "Topic for a single game's live updates (votes, phase changes)."
  def topic(game_id), do: "mafia:#{game_id}"

  def subscribe(game_id), do: Phoenix.PubSub.subscribe(Mafia.PubSub, topic(game_id))

  defp broadcast(game_id, message) do
    Phoenix.PubSub.broadcast(Mafia.PubSub, topic(game_id), message)
  end

  # ============================================================================
  # Game lifecycle
  # ============================================================================

  @doc """
  Creates a Mafia game in `:setup`, owned by `host_id`.

  `attrs` may carry `:title` and a `:ruleset` map; unknown ruleset keys fall back
  to `default_ruleset/0` via `Map.merge/2`.
  """
  def create_game(host_id, attrs \\ %{}) do
    with :ok <- WriteGate.ensure_enabled() do
      ruleset = Map.merge(default_ruleset(), Map.get(attrs, :ruleset, %{}))

      create_attrs = %{
        host_id: host_id,
        title: Map.get(attrs, :title),
        ruleset: ruleset,
        status: :setup
      }

      MafiaGame
      |> Ash.Changeset.for_create(:create, create_attrs)
      |> Ash.create(authorize?: false)
      |> tap_ok(fn _game ->
        Phoenix.PubSub.broadcast(Mafia.PubSub, "mafia:lobby", :games_changed)
      end)
    end
  end

  @doc "The default ruleset — every key the rest of the system reads has a value here."
  def default_ruleset do
    %{
      "lobby_type" => "open",
      "day_length_seconds" => 86_400,
      "night_length_seconds" => 86_400,
      "vote_type" => "majority",
      "allow_no_lynch" => true,
      "reveal_on_death" => "full",
      "night_conversation_cap" => 2
    }
  end

  def get_game(id) do
    case Ash.get(MafiaGame, id, authorize?: false) do
      {:ok, game} -> {:ok, game}
      {:error, _} -> {:error, :not_found}
    end
  end

  def get_game!(id), do: Ash.get!(MafiaGame, id, authorize?: false)

  @doc "Loads a game with its players (sorted by join time)."
  def get_game_with_players(id) do
    with {:ok, game} <- get_game(id) do
      {:ok,
       Ash.load!(game, [players: Ash.Query.sort(MafiaPlayer, :created_at)], authorize?: false)}
    end
  end

  @doc "Loads a game with players + their users (sorted), for rendering a room."
  def get_game_for_view(id) do
    with {:ok, game} <- get_game(id) do
      players_query =
        MafiaPlayer
        |> Ash.Query.sort(:created_at)
        |> Ash.Query.load(:user)

      {:ok, Ash.load!(game, [players: players_query], authorize?: false)}
    end
  end

  @doc "Open games still in `:setup` with a public (`open`) lobby."
  def list_open_games do
    MafiaGame
    |> Ash.Query.filter(status == :setup)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(fn g -> Map.get(g.ruleset || %{}, "lobby_type", "open") == "open" end)
  end

  @doc """
  Deletes a game (host only). Archives the reused chat conversations and purges
  the game's children (which have no ON DELETE CASCADE) before destroying it.
  Works at any stage; mainly used to clean up un-started lobbies.
  """
  def delete_game(%MafiaGame{} = game, host_id) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id) do
      # Purge children first — votes/night-actions reference players, so they go
      # before players, and players before the game.
      _ =
        for resource <- [MafiaNightAction, MafiaVote, MafiaPlayer] do
          _ =
            resource
            |> Ash.Query.filter(mafia_game_id == ^game.id)
            |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false)
        end

      # Only archive the chats and announce the deletion once the game is gone,
      # so a failed destroy can't leave an archived-but-still-present game.
      case Ash.destroy(game, authorize?: false) do
        {:error, _} = err ->
          err

        _ok ->
          _ =
            for conv_id <- [game.day_thread_conversation_id, game.mafia_chat_conversation_id],
                is_binary(conv_id) do
              _ = Chat.archive_conversation(conv_id, host_id)
            end

          _ = broadcast(game.id, :game_deleted)
          _ = Phoenix.PubSub.broadcast(Mafia.PubSub, "mafia:lobby", :games_changed)
          :ok
      end
    end
  end

  # ============================================================================
  # Roster
  # ============================================================================

  @doc "The lobby type from the ruleset: `\"open\"` (anyone joins) or `\"invite\"` (mod adds)."
  def lobby_type(%MafiaGame{ruleset: ruleset}), do: Map.get(ruleset || %{}, "lobby_type", "open")

  @doc """
  A user joins themselves. Only for `:setup` games with an `open` lobby —
  invite-only games reject self-join (the mod adds players via `add_player/3`).
  Idempotent: returns the existing player if already joined.
  """
  def join_game(%MafiaGame{status: :setup} = game, user_id) do
    with :ok <- WriteGate.ensure_enabled() do
      if lobby_type(game) == "invite" do
        {:error, :invite_only}
      else
        do_add_player(game, user_id)
      end
    end
  end

  def join_game(%MafiaGame{}, _user_id), do: {:error, :game_already_started}

  @doc "Mod adds a player by user id (works for both lobby types)."
  def add_player(%MafiaGame{status: :setup} = game, host_id, user_id) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id) do
      do_add_player(game, user_id)
    end
  end

  def add_player(%MafiaGame{}, _host_id, _user_id), do: {:error, :game_already_started}

  @doc "Mod adds a player by username or email (the invite-lobby roster flow)."
  def add_player_by_name(%MafiaGame{} = game, host_id, name) do
    case Mafia.Accounts.get_user_by_username_or_email(String.trim(to_string(name))) do
      nil -> {:error, :user_not_found}
      user -> add_player(game, host_id, user.id)
    end
  end

  defp do_add_player(game, user_id) do
    case fetch_player(game.id, user_id) do
      {:ok, player} ->
        {:ok, player}

      {:error, :not_found} ->
        MafiaPlayer
        |> Ash.Changeset.for_create(:create, %{mafia_game_id: game.id, user_id: user_id})
        |> Ash.create(authorize?: false)
        |> tap_ok(fn _ -> broadcast(game.id, :roster_changed) end)

      {:error, _} = err ->
        err
    end
  end

  @doc "A player leaves (only in `:setup`)."
  def leave_game(%MafiaGame{status: :setup} = game, user_id) do
    with :ok <- WriteGate.ensure_enabled(),
         {:ok, player} <- fetch_player(game.id, user_id) do
      remove_player(game, player)
    end
  end

  def leave_game(%MafiaGame{}, _user_id), do: {:error, :game_already_started}

  @doc """
  Mod removes a player. Pre-start it deletes the seat; mid-game it is a modkill
  (handled by the elimination path) — callers pass an already-started game to
  `eliminate_player/3` instead.
  """
  def kick_player(%MafiaGame{status: :setup} = game, %MafiaPlayer{} = player, host_id) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id) do
      remove_player(game, player)
    end
  end

  defp remove_player(game, player) do
    case Ash.destroy(player, authorize?: false) do
      :ok ->
        _ = broadcast(game.id, :roster_changed)
        :ok

      {:ok, _} ->
        _ = broadcast(game.id, :roster_changed)
        :ok

      other ->
        other
    end
  end

  def fetch_player(game_id, user_id) do
    MafiaPlayer
    |> Ash.Query.filter(mafia_game_id == ^game_id and user_id == ^user_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, player} -> {:ok, player}
      {:error, _} = err -> err
    end
  end

  # ============================================================================
  # Day-phase voting
  # ============================================================================

  @doc """
  Casts (or changes) `voter_user_id`'s vote in the current day phase.
  `target_player_id` may be `nil` for an explicit No Lynch.

  Enforces, at cast time: the day is open, before the deadline, and the voter is
  alive. Returns `{:error, reason}` otherwise.
  """
  def cast_vote(%MafiaGame{} = game, voter_user_id, target_player_id) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- ensure_day_open(game),
         {:ok, voter} <- fetch_player(game.id, voter_user_id),
         :ok <- ensure_alive(voter),
         :ok <- ensure_valid_target(game, target_player_id) do
      result =
        case existing_vote(game.id, game.phase_number, voter.id) do
          nil ->
            MafiaVote
            |> Ash.Changeset.for_create(:create, %{
              mafia_game_id: game.id,
              phase_number: game.phase_number,
              voter_player_id: voter.id,
              target_player_id: target_player_id
            })
            |> Ash.create(authorize?: false)

          vote ->
            vote
            |> Ash.Changeset.for_update(:update, %{target_player_id: target_player_id})
            |> Ash.update(authorize?: false)
        end

      tap_ok(result, fn _ ->
        counts = vote_counts(game)
        _ = broadcast(game.id, {:vote_changed, counts})
        maybe_hammer(game, counts)
      end)
    end
  end

  # Majority + a single target reaching the hammer ends the day immediately.
  # Plurality games only resolve at the deadline.
  defp maybe_hammer(game, %{leader: leader, tallies: tallies, hammer: hammer}) do
    ruleset = game.ruleset || %{}
    vote_type = Map.get(ruleset, "vote_type", "majority")

    # A real player can always be hammered; No Lynch only when the ruleset allows it.
    hammerable? =
      is_binary(leader) or (leader == @no_lynch and Map.get(ruleset, "allow_no_lynch", true))

    _ =
      if vote_type == "majority" and hammerable? and Map.get(tallies, leader, 0) >= hammer do
        resolve_day(get_game!(game.id))
      end

    :ok
  end

  @doc "Removes `voter_user_id`'s current-phase vote, if any."
  def retract_vote(%MafiaGame{} = game, voter_user_id) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- ensure_day_open(game),
         {:ok, voter} <- fetch_player(game.id, voter_user_id) do
      case existing_vote(game.id, game.phase_number, voter.id) do
        nil ->
          {:ok, :no_vote}

        vote ->
          _ = Ash.destroy!(vote, authorize?: false)
          _ = broadcast(game.id, {:vote_changed, vote_counts(game)})
          {:ok, :retracted}
      end
    end
  end

  @doc """
  Tallies the current phase: `%{tallies: %{target_player_id | :no_lynch => count},
  total: n, hammer: threshold, leader: pid | :no_lynch | nil}`.
  """
  def vote_counts(%MafiaGame{} = game),
    do: vote_counts(game.id, game.phase_number, living_count(game.id))

  def vote_counts(game_id, phase_number, living_count) do
    votes =
      MafiaVote
      |> Ash.Query.filter(mafia_game_id == ^game_id and phase_number == ^phase_number)
      |> Ash.read!(authorize?: false)

    tallies =
      Enum.reduce(votes, %{}, fn vote, acc ->
        key = vote.target_player_id || @no_lynch
        Map.update(acc, key, 1, &(&1 + 1))
      end)

    hammer = div(living_count, 2) + 1

    leader =
      tallies
      |> Enum.max_by(fn {_k, n} -> n end, fn -> nil end)
      |> case do
        nil -> nil
        {key, _n} -> key
      end

    %{tallies: tallies, total: length(votes), hammer: hammer, leader: leader}
  end

  @doc """
  What `user_id` currently has voted in this phase: a target player id,
  `:no_lynch`, or `nil` (no vote / not a player).
  """
  def voted_target(%MafiaGame{} = game, user_id) do
    case fetch_player(game.id, user_id) do
      {:ok, player} ->
        case existing_vote(game.id, game.phase_number, player.id) do
          nil -> nil
          vote -> vote.target_player_id || @no_lynch
        end

      _ ->
        nil
    end
  end

  defp living_count(game_id) do
    MafiaPlayer
    |> Ash.Query.filter(mafia_game_id == ^game_id and is_alive == true)
    |> Ash.count!(authorize?: false)
  end

  # ============================================================================
  # Roles (mod assigns in :setup)
  # ============================================================================

  @doc """
  Assigns roles to players. `assignments` is a list of maps with `:player_id`,
  `:role_name`, `:alignment` (`:town` | `:mafia`), and optional `:role_pm_body`.
  Only valid while the game is in `:setup`.
  """
  def assign_roles(%MafiaGame{status: :setup} = game, host_id, assignments) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id) do
      Enum.each(assignments, fn a ->
        with {:ok, player} <- fetch_player_by_id(game.id, a.player_id) do
          player
          |> Ash.Changeset.for_update(:update, %{
            role_name: Map.get(a, :role_name),
            alignment: Map.get(a, :alignment),
            role_pm_body: Map.get(a, :role_pm_body)
          })
          |> Ash.update!(authorize?: false)
        end
      end)

      _ = broadcast(game.id, :roster_changed)
      :ok
    end
  end

  def assign_roles(%MafiaGame{}, _host_id, _assignments), do: {:error, :game_already_started}

  # ============================================================================
  # Phase transitions
  # ============================================================================

  @doc """
  Starts the game: `:setup` → Day 1. Provisions the day-thread and mafia chat
  conversations, stamps the first deadline, and schedules the phase timer.

  Requires a startable roster: at least 3 players, every player aligned, and at
  least one mafia and one town.
  """
  def start_game(%MafiaGame{status: :setup} = game, host_id) do
    game = ensure_players_loaded(game)

    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id),
         :ok <- validate_startable(game),
         {:ok, day_conv} <- provision_day_thread(game),
         {:ok, mafia_conv} <- provision_mafia_chat(game) do
      {:ok, game} =
        update_game(game, %{
          status: :day,
          phase_number: 1,
          phase_ends_at: phase_deadline(game, "day_length_seconds"),
          day_thread_conversation_id: day_conv.id,
          mafia_chat_conversation_id: mafia_conv.id
        })

      post_system(game, "Day 1 begins. Discuss, and vote to lynch.")
      schedule_phase_timer(game)
      _ = broadcast(game.id, {:phase_changed, game})

      notify_phase(
        game,
        "Mafia — Day 1 begins",
        "#{game_label(game)} has started. Day 1 is open."
      )

      {:ok, game}
    end
  end

  def start_game(%MafiaGame{}, _host_id), do: {:error, :game_already_started}

  @doc """
  Resolves the current Day: auto-lynch the plurality leader (per Connor's
  deadline rule), then advance to Night — or finish if a faction has won. A
  no-op on a game that is not in `:day` (handles stale/duplicate timer fires).

  Called by `MafiaPhaseWorker`, the reconciler, and the hammer path.
  """
  def resolve_day(%MafiaGame{status: :day} = game) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- resolve_lynch(game) do
      case maybe_finish(game) do
        {:finished, finished} -> {:ok, finished}
        {:continue, game} -> advance_to_night(game)
        {:error, _reason} = error -> error
      end
    end
  end

  def resolve_day(%MafiaGame{} = game), do: {:ok, game}

  defp resolve_lynch(game) do
    case decide_lynch(game, vote_counts(game)) do
      @no_lynch ->
        if writable_day?(game),
          do: post_system(game, "The town could not agree. No one is lynched today.")

        :ok

      target_player_id ->
        with {:ok, target} <- fetch_player_by_id(game.id, target_player_id) do
          do_eliminate(game, target, :lynch)
        end
    end
  end

  @doc """
  Mod advances Night → next Day after resolving night actions by hand. Unlocks
  the day thread and posts the dawn message.
  """
  def open_next_day(%MafiaGame{status: :night} = game, host_id) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id),
         {:ok, game} <-
           update_phase(game, false, %{
             status: :day,
             phase_number: game.phase_number + 1,
             phase_ends_at: phase_deadline(game, "day_length_seconds")
           }) do
      post_system(game, "Dawn breaks on Day #{day_number(game)}.")
      schedule_phase_timer(game)
      _ = broadcast(game.id, {:phase_changed, game})
      notify_phase(game, "Mafia — Day #{day_number(game)}", "Dawn breaks. The day phase is open.")
      {:ok, game}
    end
  end

  def open_next_day(%MafiaGame{}, _host_id), do: {:error, :not_night_phase}

  @doc "Broadcasts a nudge that a night phase is past its deadline (mod must resolve)."
  def nudge_night_overdue(%MafiaGame{} = game) do
    with :ok <- WriteGate.ensure_enabled() do
      _ = broadcast(game.id, {:night_overdue, game})
      :ok
    end
  end

  defp advance_to_night(%MafiaGame{} = game) do
    with {:ok, game} <-
           update_phase(game, true, %{
             status: :night,
             phase_number: game.phase_number + 1,
             phase_ends_at: phase_deadline(game, "night_length_seconds")
           }) do
      # System messages are allowed through a read-only day thread. Post only
      # after the lock + phase update commit so a failed transition can't claim
      # that night began while the game is still in Day.
      post_system(game, "Night falls. The town sleeps while the mafia move.")

      schedule_phase_timer(game)
      _ = broadcast(game.id, {:phase_changed, game})

      notify_phase(
        game,
        "Mafia — Night #{day_number(game)}",
        "Night falls. Submit a night action if your role has one."
      )

      {:ok, game}
    end
  end

  # ============================================================================
  # Eliminations + win check
  # ============================================================================

  @doc """
  Mod-driven elimination: a night kill (`:night`) or a modkill (`:modkill`).
  Mutes the player, reveals if configured, and finishes the game if a faction
  has won. Day-lynches go through `resolve_day/1`.
  """
  def eliminate(%MafiaGame{} = game, player_id, reason, host_id)
      when reason in [:night, :modkill] do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id),
         {:ok, player} <- fetch_player_by_id(game.id, player_id),
         :ok <- do_eliminate(game, player, reason) do
      case maybe_finish(game) do
        {:finished, finished} -> {:ok, finished}
        {:continue, game} -> {:ok, game}
        {:error, _reason} = error -> error
      end
    end
  end

  defp do_eliminate(game, player, reason) do
    case Repo.transaction(fn ->
           with {:ok, _player} <-
                  player
                  |> Ash.Changeset.for_update(:update, %{
                    is_alive: false,
                    eliminated_by: reason,
                    eliminated_phase: game.phase_number
                  })
                  |> Ash.update(authorize?: false),
                :ok <- shadow_mute_player(game, player.user_id) do
             :ok
           else
             {:error, error} -> Repo.rollback(error)
           end
         end) do
      {:ok, :ok} ->
        # Flips are announced in the open day thread (lynches/day-modkills).
        # Night deaths are revealed at dawn / shown in the room UI.
        if writable_day?(game) and reveal_on_death?(game),
          do: post_system(game, flip_text(game, player))

        _ = broadcast(game.id, :roster_changed)
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp shadow_mute_player(%{day_thread_conversation_id: nil}, _user_id), do: :ok

  defp shadow_mute_player(game, user_id) do
    case Chat.shadow_mute_member(
           game.day_thread_conversation_id,
           game.host_id,
           user_id,
           true
         ) do
      {:ok, _membership} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # Returns {:finished, game} | {:continue, game}. Vanilla two-faction win:
  # town wins when no mafia live; mafia win on parity (>= town).
  defp maybe_finish(game) do
    players =
      MafiaPlayer
      |> Ash.Query.filter(mafia_game_id == ^game.id and is_alive == true)
      |> Ash.read!(authorize?: false)

    mafia = Enum.count(players, &(&1.alignment == :mafia))
    town = Enum.count(players, &(&1.alignment != :mafia))

    cond do
      mafia == 0 -> finish_result(game, :town)
      mafia >= town -> finish_result(game, :mafia)
      true -> {:continue, game}
    end
  end

  defp finish_result(game, faction) do
    case finish_game(game, faction) do
      {:ok, finished} -> {:finished, finished}
      {:error, _reason} = error -> error
    end
  end

  # The day-thread rule and Mafia phase are one invariant. Both Ash resources
  # share Mafia.Repo, so an outer transaction prevents a writable night (or
  # locked day) when either update fails.
  defp update_phase(game, read_only?, attrs) do
    Repo.transaction(fn ->
      with :ok <- set_day_thread_read_only(game, read_only?),
           {:ok, updated} <- update_game(game, attrs) do
        updated
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp set_day_thread_read_only(%{day_thread_conversation_id: nil}, _read_only?), do: :ok

  defp set_day_thread_read_only(game, read_only?) do
    case Chat.set_conversation_read_only(
           game.day_thread_conversation_id,
           game.host_id,
           read_only?
         ) do
      {:ok, _conversation} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp finish_game(game, faction) do
    with {:ok, game} <-
           update_phase(game, false, %{
             status: :finished,
             winner_faction: faction,
             phase_ends_at: nil
           }) do
      post_system(game, "Game over — the #{faction} win.")
      _ = broadcast(game.id, {:phase_changed, game})
      notify_phase(game, "Mafia — game over", "The #{faction} win #{game_label(game)}.")
      {:ok, game}
    end
  end

  # ============================================================================
  # Night actions (collected, mod resolves)
  # ============================================================================

  @doc """
  Submits (or updates) a night action for `actor_user_id`. Collection only — the
  mod resolves by hand. Enforces: night is open, before the deadline, actor alive.
  """
  def submit_night_action(%MafiaGame{} = game, actor_user_id, action_kind, target_player_id) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- ensure_night(game),
         {:ok, actor_player} <- fetch_player(game.id, actor_user_id),
         :ok <- ensure_alive(actor_player) do
      result =
        case existing_night_action(game.id, game.phase_number, actor_player.id, action_kind) do
          nil ->
            MafiaNightAction
            |> Ash.Changeset.for_create(:create, %{
              mafia_game_id: game.id,
              phase_number: game.phase_number,
              actor_player_id: actor_player.id,
              action_kind: action_kind,
              target_player_id: target_player_id
            })
            |> Ash.create(authorize?: false)

          action ->
            action
            |> Ash.Changeset.for_update(:update, %{target_player_id: target_player_id})
            |> Ash.update(authorize?: false)
        end

      tap_ok(result, fn _ -> broadcast(game.id, :night_actions_changed) end)
    end
  end

  @doc "All night-action submissions for the current phase (mod view)."
  def list_night_actions(%MafiaGame{} = game) do
    MafiaNightAction
    |> Ash.Query.filter(mafia_game_id == ^game.id and phase_number == ^game.phase_number)
    |> Ash.Query.load(actor_player: :user, target_player: :user)
    |> Ash.read!(authorize?: false)
  end

  @doc "Mod records the outcome of a night action."
  def resolve_night_action(%MafiaGame{} = game, action_id, mod_result, host_id) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id),
         {:ok, action} <- get_night_action(game.id, action_id) do
      action
      |> Ash.Changeset.for_update(:resolve, %{mod_result: mod_result})
      |> Ash.update(authorize?: false)
      |> tap_ok(fn _ -> broadcast(game.id, :night_actions_changed) end)
    end
  end

  # ============================================================================
  # Internal guards / helpers
  # ============================================================================

  defp ensure_players_loaded(%MafiaGame{players: %Ash.NotLoaded{}} = game),
    do: Ash.load!(game, :players, authorize?: false)

  defp ensure_players_loaded(%MafiaGame{} = game), do: game

  defp validate_startable(%MafiaGame{players: players}) do
    aligned = Enum.filter(players, &(&1.alignment in [:town, :mafia]))
    mafia = Enum.count(aligned, &(&1.alignment == :mafia))
    town = Enum.count(aligned, &(&1.alignment == :town))

    cond do
      length(players) < 3 -> {:error, :need_at_least_3_players}
      length(aligned) != length(players) -> {:error, :all_players_need_a_role}
      mafia < 1 -> {:error, :need_at_least_one_mafia}
      town < 1 -> {:error, :need_at_least_one_town}
      true -> :ok
    end
  end

  defp provision_day_thread(game) do
    Chat.create_group_conversation(game.host_id, Enum.map(game.players, & &1.user_id),
      title: "#{game_label(game)} — Town Square",
      metadata: %{"mafia_game_id" => game.id, "channel" => "day_thread"}
    )
  end

  defp provision_mafia_chat(game) do
    mafia_ids =
      game.players |> Enum.filter(&(&1.alignment == :mafia)) |> Enum.map(& &1.user_id)

    Chat.create_group_conversation(game.host_id, mafia_ids,
      title: "#{game_label(game)} — Mafia",
      metadata: %{"mafia_game_id" => game.id, "channel" => "mafia"}
    )
  end

  defp game_label(%MafiaGame{title: nil}), do: "Mafia"
  defp game_label(%MafiaGame{title: title}), do: title

  defp update_game(game, attrs) do
    game
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(authorize?: false)
  end

  defp authorize_host(%MafiaGame{host_id: host_id}, host_id), do: :ok
  defp authorize_host(%MafiaGame{}, _other), do: {:error, :not_host}

  defp phase_deadline(game, ruleset_key) do
    seconds = Map.get(game.ruleset || %{}, ruleset_key, 86_400)

    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.truncate(:second)
  end

  defp schedule_phase_timer(%MafiaGame{phase_ends_at: nil}), do: :ok

  defp schedule_phase_timer(%MafiaGame{} = game) do
    seconds = max(DateTime.diff(game.phase_ends_at, DateTime.utc_now()), 0)

    _ =
      %{mafia_game_id: game.id, phase_number: game.phase_number}
      |> MafiaPhaseWorker.new(schedule_in: seconds)
      |> Oban.insert()

    :ok
  end

  # `phase_number` is a monotonic counter (Day 1 = 1, Night 1 = 2, Day 2 = 3…).
  # The human-facing day number is ceil(phase_number / 2).
  defp day_number(%MafiaGame{phase_number: n}), do: div(n + 1, 2)

  defp writable_day?(%MafiaGame{status: :day}), do: true
  defp writable_day?(%MafiaGame{}), do: false

  defp reveal_on_death?(%MafiaGame{ruleset: ruleset}),
    do: Map.get(ruleset || %{}, "reveal_on_death", "full") != "none"

  defp flip_text(game, player) do
    role = player.role_name || "an unknown role"

    case Map.get(game.ruleset || %{}, "reveal_on_death", "full") do
      "alignment" -> "A player has died. They were #{player.alignment}."
      _ -> "A player has died. They were #{role} (#{player.alignment})."
    end
  end

  defp post_system(%MafiaGame{day_thread_conversation_id: nil}, _body), do: :ok

  defp post_system(%MafiaGame{day_thread_conversation_id: conv_id, host_id: host_id}, body) do
    # system: true so phase-transition narration still posts while the day thread
    # is locked read-only (night flips announce deaths into a closed thread).
    _ = Chat.send_message(conv_id, host_id, body, system: true)
    :ok
  end

  defp decide_lynch(_game, %{tallies: tallies}) when map_size(tallies) == 0, do: @no_lynch

  defp decide_lynch(_game, %{tallies: tallies}) do
    {key, max} = Enum.max_by(tallies, fn {_k, n} -> n end)
    tie? = Enum.count(tallies, fn {_k, n} -> n == max end) > 1

    cond do
      tie? -> @no_lynch
      key == @no_lynch -> @no_lynch
      true -> key
    end
  end

  defp ensure_night(%MafiaGame{status: :night} = game) do
    cond do
      is_nil(game.phase_ends_at) -> :ok
      DateTime.compare(DateTime.utc_now(), game.phase_ends_at) == :lt -> :ok
      true -> {:error, :phase_closed}
    end
  end

  defp ensure_night(%MafiaGame{}), do: {:error, :not_night_phase}

  defp existing_night_action(game_id, phase_number, actor_player_id, action_kind) do
    MafiaNightAction
    |> Ash.Query.filter(
      mafia_game_id == ^game_id and phase_number == ^phase_number and
        actor_player_id == ^actor_player_id and action_kind == ^action_kind
    )
    |> Ash.read_one!(authorize?: false)
  end

  defp get_night_action(game_id, action_id) do
    MafiaNightAction
    |> Ash.Query.filter(mafia_game_id == ^game_id and id == ^action_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, action} -> {:ok, action}
      err -> err
    end
  end

  defp existing_vote(game_id, phase_number, voter_player_id) do
    MafiaVote
    |> Ash.Query.filter(
      mafia_game_id == ^game_id and phase_number == ^phase_number and
        voter_player_id == ^voter_player_id
    )
    |> Ash.read_one!(authorize?: false)
  end

  defp ensure_day_open(%MafiaGame{status: :day} = game) do
    cond do
      is_nil(game.phase_ends_at) -> :ok
      DateTime.compare(DateTime.utc_now(), game.phase_ends_at) == :lt -> :ok
      true -> {:error, :phase_closed}
    end
  end

  defp ensure_day_open(%MafiaGame{}), do: {:error, :not_day_phase}

  defp ensure_alive(%MafiaPlayer{is_alive: true}), do: :ok
  defp ensure_alive(%MafiaPlayer{}), do: {:error, :dead_players_cannot_vote}

  defp ensure_valid_target(_game, nil), do: :ok

  defp ensure_valid_target(game, target_player_id) do
    case fetch_player_by_id(game.id, target_player_id) do
      {:ok, %MafiaPlayer{is_alive: true}} -> :ok
      {:ok, %MafiaPlayer{}} -> {:error, :target_not_alive}
      _ -> {:error, :invalid_target}
    end
  end

  defp fetch_player_by_id(game_id, player_id) do
    MafiaPlayer
    |> Ash.Query.filter(mafia_game_id == ^game_id and id == ^player_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, player} -> {:ok, player}
      err -> err
    end
  end

  # Returns the input on `{:ok, _}` / `:ok` after running `fun`, passing errors
  # through untouched.
  defp tap_ok({:ok, value} = result, fun) do
    _ = fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other

  # Notify the roster + host of a phase change. Best-effort — a notification
  # failure must never break a phase transition.
  defp notify_phase(game, title, body) do
    recipients = Enum.uniq([game.host_id | player_user_ids(game.id)])
    _ = Mafia.Notifications.notify_mafia_phase(recipients, game.id, title, body)
    :ok
  rescue
    _ -> :ok
  end

  defp player_user_ids(game_id) do
    MafiaPlayer
    |> Ash.Query.filter(mafia_game_id == ^game_id)
    |> Ash.Query.select([:user_id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.user_id)
  end
end
