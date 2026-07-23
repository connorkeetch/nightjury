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

  alias Mafia.{Chat, GameRules, Repo, WriteGate}

  alias Mafia.Games.Resources.{
    MafiaGame,
    MafiaNightAction,
    MafiaNotebook,
    MafiaPlayer,
    MafiaRuleRevision,
    MafiaVote
  }

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

  defp refresh_lobby do
    Phoenix.PubSub.broadcast(Mafia.PubSub, "mafia:lobby", :games_changed)
  end

  defp game_chat_snapshot(game) do
    {
      Chat.list_game_conversations(game.id),
      Enum.uniq([game.host_id | player_user_ids(game.id)])
    }
  end

  defp refresh_game_chats(game, previous_snapshot \\ {[], []}) do
    {previous_conversations, previous_user_ids} = previous_snapshot
    {current_conversations, current_user_ids} = game_chat_snapshot(game)

    conversations =
      Enum.uniq_by(previous_conversations ++ current_conversations, & &1.id)

    user_ids = Enum.uniq(previous_user_ids ++ current_user_ids)
    publish_game_chat_refreshes(conversations, user_ids)
  end

  defp publish_game_chat_refreshes(conversations, user_ids) do
    Enum.each(conversations, &Chat.refresh_conversation(&1.id))
    Chat.refresh_user_conversations(user_ids)
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
      ruleset = GameRules.normalize(Map.get(attrs, :ruleset, %{}))

      create_attrs = %{
        host_id: host_id,
        title: Map.get(attrs, :title),
        ruleset: ruleset,
        status: :setup
      }

      result =
        Repo.transaction(fn ->
          with {:ok, game} <-
                 MafiaGame
                 |> Ash.Changeset.for_create(:create, create_attrs)
                 |> Ash.create(authorize?: false),
               {:ok, _revision} <- create_rule_revision(game, host_id) do
            game
          else
            {:error, error} -> Repo.rollback(error)
          end
        end)

      case result do
        {:ok, game} ->
          _ = refresh_lobby()
          {:ok, game}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc "The default ruleset — every key the rest of the system reads has a value here."
  def default_ruleset, do: GameRules.default()

  @doc "Updates normalized game rules and records an immutable revision snapshot."
  def update_rules(%MafiaGame{} = game, host_id, expected_revision, ruleset, summary) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id),
         :ok <- ensure_revision(game, expected_revision) do
      normalized = GameRules.normalize(ruleset)
      chat_snapshot = game_chat_snapshot(game)

      result =
        Repo.transaction(fn ->
          current = get_game!(game.id)
          normalized = reconcile_legacy_alignment_compatibility(current, normalized)

          with :ok <- ensure_revision(current, expected_revision),
               :ok <- ensure_rules_compatible(current, normalized),
               {:ok, updated} <-
                 update_game(current, %{
                   ruleset: normalized,
                   rules_revision: current.rules_revision + 1
                 }),
               {:ok, _revision} <- create_rule_revision(updated, host_id, summary),
               :ok <- apply_current_chat_rules(updated),
               :ok <- sync_player_mutes(updated),
               :ok <- sync_private_faction_chats(updated),
               {:ok, resolved} <- resolve_configuration_victory(get_game!(updated.id)) do
            resolved
          else
            {:error, error} -> Repo.rollback(error)
          end
        end)

      case result do
        {:ok, updated} ->
          schedule_phase_timer(updated)
          _ = broadcast(updated.id, {:rules_changed, updated.rules_revision})
          _ = refresh_game_chats(updated, chat_snapshot)
          {:ok, updated}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  def update_rules(%MafiaGame{} = game, host_id, expected_revision, ruleset)
      when is_integer(expected_revision) and is_map(ruleset),
      do: update_rules(game, host_id, expected_revision, ruleset, "")

  def update_rules(%MafiaGame{} = game, host_id, ruleset, summary) when is_map(ruleset),
    do: update_rules(game, host_id, game.rules_revision, ruleset, summary)

  def update_rules(%MafiaGame{} = game, host_id, ruleset),
    do: update_rules(game, host_id, game.rules_revision, ruleset, "")

  @doc "Returns all persisted rule revisions, newest first."
  def list_rule_revisions(%MafiaGame{} = game) do
    MafiaRuleRevision
    |> Ash.Query.filter(mafia_game_id == ^game.id)
    |> Ash.Query.sort(revision: :desc)
    |> Ash.Query.load(:changed_by)
    |> Ash.read!(authorize?: false)
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
    |> Enum.filter(&(lobby_type(&1) == "open"))
  end

  @doc "Games a user hosts or has a seat in, including started and finished games."
  def list_user_games(user_id) do
    hosted =
      MafiaGame
      |> Ash.Query.filter(host_id == ^user_id)
      |> Ash.read!(authorize?: false)

    joined =
      MafiaPlayer
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.Query.load(:mafia_game)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.mafia_game)

    (hosted ++ joined)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  @doc """
  Deletes a game (host only). Database cascades remove the game's child records,
  then the reused chat conversations are archived. Works at any stage.
  """
  def delete_game(%MafiaGame{} = game, host_id) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id) do
      conversations = Chat.list_game_conversations(game.id)
      user_ids = Enum.uniq([host_id | player_user_ids(game.id)])

      result =
        Repo.transaction(fn ->
          with :ok <- archive_game_conversations(conversations, host_id),
               :ok <- destroy_game(game) do
            :ok
          else
            {:error, error} -> Repo.rollback(error)
          end
        end)

      case result do
        {:ok, :ok} ->
          _ = broadcast(game.id, :game_deleted)
          _ = refresh_lobby()
          _ = publish_game_chat_refreshes(conversations, user_ids)
          :ok

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # ============================================================================
  # Roster
  # ============================================================================

  @doc "The lobby type from the ruleset: `\"open\"` (anyone joins) or `\"invite\"` (mod adds)."
  def lobby_type(%MafiaGame{ruleset: ruleset}), do: GameRules.normalize(ruleset)["lobby_type"]

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
        with :ok <- ensure_roster_capacity(game) do
          MafiaPlayer
          |> Ash.Changeset.for_create(:create, %{mafia_game_id: game.id, user_id: user_id})
          |> Ash.create(authorize?: false)
          |> tap_ok(fn _ ->
            _ = broadcast(game.id, :roster_changed)
            _ = refresh_lobby()
          end)
        end

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
        _ = refresh_lobby()
        :ok

      {:ok, _} ->
        _ = broadcast(game.id, :roster_changed)
        _ = refresh_lobby()
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

  defp ensure_roster_capacity(game) do
    max_players = GameRules.normalize(game.ruleset)["max_players"]

    if max_players > 0 and player_count(game.id) >= max_players,
      do: {:error, :game_full},
      else: :ok
  end

  defp player_count(game_id) do
    MafiaPlayer
    |> Ash.Query.filter(mafia_game_id == ^game_id)
    |> Ash.count!(authorize?: false)
  end

  @doc "Checks a reusable capability after applying the player's status and overrides."
  def player_can?(%MafiaGame{} = game, %MafiaPlayer{} = player, capability),
    do: GameRules.capability?(game.ruleset, player, capability)

  @doc "Moderator update for a player's faction, status, tags, role, or capability overrides."
  def moderate_player(%MafiaGame{} = game, player_id, host_id, attrs) when is_map(attrs) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id),
         {:ok, normalized} <- normalize_player_attrs(attrs) do
      chat_snapshot = game_chat_snapshot(game)

      result =
        Repo.transaction(fn ->
          current = get_game!(game.id)

          with :ok <- authorize_host(current, host_id),
               {:ok, current_player} <- fetch_player_by_id(current.id, player_id),
               :ok <- ensure_player_update_compatible(current, current_player, normalized),
               {:ok, updated} <-
                 current_player
                 |> Ash.Changeset.for_update(:update, normalized)
                 |> Ash.update(authorize?: false),
               :ok <- sync_player_mute(current, updated),
               :ok <- sync_private_faction_chats(current),
               {:ok, _resolved_game} <- resolve_configuration_victory(get_game!(current.id)) do
            updated
          else
            {:error, error} -> Repo.rollback(error)
          end
        end)

      case result do
        {:ok, updated} ->
          _ = broadcast(game.id, :roster_changed)
          _ = refresh_game_chats(get_game!(game.id), chat_snapshot)
          {:ok, updated}

        {:error, error} ->
          {:error, error}
      end
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
    cast_ballot(game, voter_user_id, "elimination", target_player_id)
  end

  @doc "Casts or changes a choice on a named, ruleset-defined ballot."
  def cast_ballot(%MafiaGame{} = game, voter_user_id, ballot_key, target_player_id) do
    with :ok <- WriteGate.ensure_enabled(),
         {:ok, ballot} <- fetch_open_ballot(game, ballot_key),
         {:ok, voter} <- fetch_player(game.id, voter_user_id),
         :ok <- ensure_ballot_voter(game, voter, ballot),
         :ok <- ensure_ballot_target(game, voter, target_player_id, ballot) do
      result =
        case existing_vote(game.id, game.phase_number, ballot["key"], voter.id) do
          nil ->
            MafiaVote
            |> Ash.Changeset.for_create(:create, %{
              mafia_game_id: game.id,
              phase_number: game.phase_number,
              ballot_key: ballot["key"],
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
        counts = ballot_totals(game, ballot["key"])
        _ = broadcast(game.id, {:ballot_changed, ballot["key"]})
        maybe_hammer(game, ballot, counts)
      end)
    end
  end

  defp maybe_hammer(game, ballot, %{leader: leader, tallies: tallies, hammer: hammer}) do
    elimination = elimination_ballot(game)

    hammerable? =
      is_binary(leader) or (leader == @no_lynch and ballot["allow_no_result"])

    if (elimination && ballot["key"] == elimination["key"]) and ballot["method"] == "majority" and
         ballot["effect"] == "eliminate" and hammerable? and
         Map.get(tallies, leader, 0) >= hammer do
      _ = resolve_day(get_game!(game.id))
    end

    :ok
  end

  @doc "Removes `voter_user_id`'s current-phase vote, if any."
  def retract_vote(%MafiaGame{} = game, voter_user_id) do
    retract_ballot(game, voter_user_id, "elimination")
  end

  @doc "Retracts the user's choice from a named ballot."
  def retract_ballot(%MafiaGame{} = game, voter_user_id, ballot_key) do
    with :ok <- WriteGate.ensure_enabled(),
         {:ok, ballot} <- fetch_open_ballot(game, ballot_key),
         {:ok, voter} <- fetch_player(game.id, voter_user_id) do
      case existing_vote(game.id, game.phase_number, ballot["key"], voter.id) do
        nil ->
          {:ok, :no_vote}

        vote ->
          _ = Ash.destroy!(vote, authorize?: false)
          _ = broadcast(game.id, {:ballot_changed, ballot["key"]})
          {:ok, :retracted}
      end
    end
  end

  @doc """
  Tallies the current phase: `%{tallies: %{target_player_id | :no_lynch => count},
  total: n, hammer: threshold, leader: pid | :no_lynch | nil}`.
  """
  def vote_counts(%MafiaGame{} = game),
    do: ballot_totals(game, "elimination")

  def vote_counts(game_id, phase_number, living_count) do
    votes =
      MafiaVote
      |> Ash.Query.filter(
        mafia_game_id == ^game_id and phase_number == ^phase_number and
          ballot_key == "elimination"
      )
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

  @doc "Server-side totals for a named ballot, filtered through current eligibility rules."
  def ballot_totals(%MafiaGame{} = game, ballot_key) do
    case GameRules.ballot(game.ruleset, ballot_key) do
      nil ->
        empty_totals()

      ballot ->
        ballot_key = ballot["key"]

        votes =
          MafiaVote
          |> Ash.Query.filter(
            mafia_game_id == ^game.id and phase_number == ^game.phase_number and
              ballot_key == ^ballot_key
          )
          |> Ash.Query.load(voter: :user, target: :user)
          |> Ash.read!(authorize?: false)
          |> Enum.filter(&eligible_vote?(game, &1, ballot))

        tallies =
          Enum.reduce(votes, %{}, fn vote, acc ->
            key = vote.target_player_id || @no_lynch
            Map.update(acc, key, 1, &(&1 + 1))
          end)

        leader =
          tallies
          |> Enum.max_by(fn {_key, count} -> count end, fn -> nil end)
          |> case do
            nil -> nil
            {key, _count} -> key
          end

        eligible_voters = eligible_voters(game, ballot)
        voted_ids = MapSet.new(votes, & &1.voter_player_id)

        voters_by_target =
          if ballot["show_voters"] do
            votes
            |> Enum.group_by(&(&1.target_player_id || @no_lynch), &player_username(&1.voter))
            |> Map.new(fn {target, usernames} -> {target, Enum.sort(usernames)} end)
          else
            %{}
          end

        unvoted =
          if ballot["show_voters"] do
            eligible_voters
            |> Enum.reject(&MapSet.member?(voted_ids, &1.id))
            |> Enum.map(&player_username/1)
            |> Enum.sort()
          else
            []
          end

        %{
          tallies: tallies,
          total: length(votes),
          hammer: div(length(eligible_voters), 2) + 1,
          leader: leader,
          voters_by_target: voters_by_target,
          unvoted: unvoted
        }
    end
  end

  @doc "Applies ballot visibility for a player or guest without leaking hidden tallies."
  def visible_ballot_totals(%MafiaGame{} = game, ballot_key, viewer_id \\ nil) do
    totals = ballot_totals(game, ballot_key)
    ballot = GameRules.ballot(game.ruleset, ballot_key)

    visible =
      if viewer_id == game.host_id or is_nil(ballot) or ballot["visibility"] == "live" do
        totals
      else
        case ballot["visibility"] do
          "totals" -> %{totals | tallies: %{}, leader: nil}
          _ -> %{totals | tallies: %{}, total: 0, leader: nil}
        end
      end

    if is_nil(ballot) or not ballot["show_voters"] or
         (viewer_id != game.host_id and ballot["visibility"] != "live") do
      %{visible | voters_by_target: %{}, unvoted: []}
    else
      visible
    end
  end

  @doc """
  What `user_id` currently has voted in this phase: a target player id,
  `:no_lynch`, or `nil` (no vote / not a player).
  """
  def voted_target(%MafiaGame{} = game, user_id) do
    ballot_choice(game, user_id, "elimination")
  end

  @doc "The user's current choice on a named ballot."
  def ballot_choice(%MafiaGame{} = game, user_id, ballot_key) do
    case fetch_player(game.id, user_id) do
      {:ok, player} ->
        case existing_vote(game.id, game.phase_number, to_string(ballot_key), player.id) do
          nil -> nil
          vote -> vote.target_player_id || @no_lynch
        end

      _ ->
        nil
    end
  end

  # ============================================================================
  # Roles (mod assigns in :setup)
  # ============================================================================

  @doc """
  Assigns roles to players. `assignments` is a list of maps with `:player_id`,
  `:role_name`, a configured faction key in `:alignment`, and optional `:role_pm_body`.
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
            alignment: normalize_faction(Map.get(a, :alignment)),
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
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id) do
      result =
        Repo.transaction(fn ->
          with :ok <- lock_game_for_update(game.id),
               current = game.id |> get_game!() |> ensure_players_loaded(),
               :ok <- authorize_host(current, host_id),
               :ok <- ensure_setup_game(current),
               :ok <- validate_startable(current),
               {:ok, day_conv} <- provision_day_thread(current),
               {:ok, faction_conversations} <- provision_private_faction_chats(current),
               mafia_conv = Map.get(faction_conversations, "mafia"),
               {:ok, started} <-
                 update_game(current, %{
                   status: :day,
                   phase_number: 1,
                   phase_ends_at: phase_deadline(current, "day_length_seconds"),
                   day_thread_conversation_id: day_conv.id,
                   mafia_chat_conversation_id: mafia_conv && mafia_conv.id
                 }),
               :ok <- sync_player_mutes(started),
               :ok <- sync_private_faction_chats(started) do
            get_game!(started.id)
          else
            {:error, error} -> Repo.rollback(error)
          end
        end)

      case result do
        {:ok, started} ->
          post_system(started, "Day 1 begins. Discuss, and vote to lynch.")
          schedule_phase_timer(started)
          _ = broadcast(started.id, {:phase_changed, started})
          _ = refresh_lobby()
          _ = refresh_game_chats(started)

          notify_phase(
            started,
            "Mafia — Day 1 begins",
            "#{game_label(started)} has started. Day 1 is open."
          )

          {:ok, started}

        {:error, error} ->
          {:error, error}
      end
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
    with :ok <- WriteGate.ensure_enabled() do
      chat_snapshot = game_chat_snapshot(game)

      result =
        Repo.transaction(fn ->
          with :ok <- lock_game_for_update(game.id) do
            current = get_game!(game.id)

            if current.status == :day and current.phase_number == game.phase_number do
              case resolve_locked_day(current) do
                {:ok, resolved} -> resolved
                {:error, reason} -> Repo.rollback(reason)
              end
            else
              current
            end
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, resolved} ->
          publish_resolved_day(resolved, chat_snapshot)
          {:ok, resolved}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def resolve_day(%MafiaGame{} = game), do: {:ok, game}

  defp resolve_locked_day(game) do
    with :ok <- resolve_lynch(game) do
      case maybe_finish(game) do
        {:finished, finished} -> {:ok, finished}
        {:continue, game} -> advance_to_night(game)
        {:error, _reason} = error -> error
      end
    end
  end

  defp publish_resolved_day(game, chat_snapshot) do
    _ = broadcast(game.id, {:phase_changed, game})
    _ = refresh_lobby()
    _ = refresh_game_chats(game, chat_snapshot)

    _ =
      game.id
      |> player_user_ids()
      |> then(&Mafia.Notifications.refresh_users([game.host_id | &1]))

    :ok
  end

  defp resolve_lynch(game) do
    ballot = elimination_ballot(game)
    counts = if ballot, do: ballot_totals(game, ballot["key"]), else: empty_totals()

    if ballot && ballot["method"] != "moderator" do
      case decide_lynch(game, counts) do
        @no_lynch ->
          if writable_day?(game),
            do: post_system(game, "The town could not agree. No one is lynched today.")

          :ok

        target_player_id ->
          with {:ok, target} <- fetch_player_by_id(game.id, target_player_id) do
            do_eliminate(game, target, :lynch)
          end
      end
    else
      :ok
    end
  end

  @doc """
  Mod advances Night → next Day after resolving night actions by hand. Unlocks
  the day thread and posts the dawn message.
  """
  def open_next_day(%MafiaGame{status: :night} = game, host_id) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id),
         chat_snapshot = game_chat_snapshot(game),
         {:ok, game} <-
           update_phase(game, false, %{
             status: :day,
             phase_number: game.phase_number + 1,
             phase_ends_at: phase_deadline(game, "day_length_seconds")
           }) do
      post_system(game, "Dawn breaks on Day #{day_number(game)}.")
      schedule_phase_timer(game)
      _ = broadcast(game.id, {:phase_changed, game})
      _ = refresh_lobby()
      _ = refresh_game_chats(game, chat_snapshot)
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

  @doc "Handles an overdue phase according to the current automation rules."
  def handle_phase_deadline(%MafiaGame{status: :day} = game) do
    ballot = elimination_ballot(game)

    if (GameRules.auto_resolve_day?(game.ruleset) and ballot) && ballot["method"] != "moderator" do
      resolve_day(game)
    else
      with :ok <- WriteGate.ensure_enabled() do
        _ = broadcast(game.id, {:day_overdue, game})
        :ok
      end
    end
  end

  def handle_phase_deadline(%MafiaGame{status: :night} = game), do: nudge_night_overdue(game)
  def handle_phase_deadline(%MafiaGame{} = game), do: {:ok, game}

  defp advance_to_night(%MafiaGame{} = game) do
    with {:ok, game} <-
           update_phase(game, not GameRules.day_thread_open?(game.ruleset, :night), %{
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
         chat_snapshot = game_chat_snapshot(game),
         :ok <- do_eliminate(game, player, reason) do
      result =
        case maybe_finish(get_game!(game.id)) do
          {:finished, finished} -> {:ok, finished}
          {:continue, game} -> {:ok, game}
          {:error, _reason} = error -> error
        end

      case result do
        {:ok, resolved} ->
          _ = refresh_game_chats(resolved, chat_snapshot)
          result

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp do_eliminate(game, player, reason) do
    case Repo.transaction(fn ->
           with {:ok, updated_player} <-
                  player
                  |> Ash.Changeset.for_update(:update, %{
                    is_alive: false,
                    status: "dead",
                    eliminated_by: reason,
                    eliminated_phase: game.phase_number
                  })
                  |> Ash.update(authorize?: false),
                :ok <- sync_player_mute(game, updated_player),
                :ok <- sync_private_faction_chats(game) do
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

  # Returns {:finished, game} | {:continue, game}. Vanilla two-faction win:
  # town wins when no mafia live; mafia win on parity (>= town).
  defp maybe_finish(game) do
    if GameRules.normalize(game.ruleset)["win_mode"] == "moderator" do
      {:continue, game}
    else
      maybe_finish_classic(game)
    end
  end

  defp maybe_finish_classic(game) do
    players =
      MafiaPlayer
      |> Ash.Query.filter(mafia_game_id == ^game.id and status == "active")
      |> Ash.read!(authorize?: false)

    faction_keys = Enum.map(players, &faction_key(&1.alignment))
    mafia = Enum.count(faction_keys, &(&1 == "mafia"))
    town = Enum.count(faction_keys, &(&1 == "town"))

    cond do
      Enum.any?(faction_keys, &(&1 not in ["town", "mafia"])) -> {:continue, game}
      mafia == 0 -> finish_result(game, "town")
      mafia >= town -> finish_result(game, "mafia")
      true -> {:continue, game}
    end
  end

  defp finish_result(game, faction) do
    case do_finish_game(game, faction) do
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
           {:ok, updated} <- update_game(game, attrs),
           :ok <- sync_private_faction_chats(updated) do
        get_game!(updated.id)
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

  defp do_finish_game(game, faction) do
    with {:ok, game} <-
           update_phase(game, false, %{
             status: :finished,
             winner_faction: faction,
             phase_ends_at: nil
           }) do
      faction_name = GameRules.faction_name(game.ruleset, faction) || faction
      post_system(game, "Game over — the #{faction_name} win.")
      _ = broadcast(game.id, {:phase_changed, game})
      _ = refresh_lobby()
      notify_phase(game, "Mafia — game over", "The #{faction_name} win #{game_label(game)}.")
      {:ok, game}
    end
  end

  @doc "Moderator override that closes the game with any non-empty faction label."
  def declare_winner(%MafiaGame{} = game, faction, host_id) do
    faction = faction |> to_string() |> String.trim() |> String.slice(0, 100)

    with :ok <- WriteGate.ensure_enabled(),
         :ok <- authorize_host(game, host_id),
         :ok <- if(faction == "", do: {:error, :winner_required}, else: :ok),
         chat_snapshot = game_chat_snapshot(game) do
      case do_finish_game(game, faction) do
        {:ok, finished} = result ->
          _ = refresh_game_chats(finished, chat_snapshot)
          result

        {:error, _reason} = error ->
          error
      end
    end
  end

  def finish_game(%MafiaGame{} = game, faction, host_id),
    do: declare_winner(game, faction, host_id)

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
         :ok <- ensure_capability(game, actor_player, "act"),
         :ok <- ensure_action_target(game, target_player_id) do
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
  # Private notebook + player-created side chats
  # ============================================================================

  @doc "Returns the user's private notes as general text plus player-id keys."
  def notebook(%MafiaGame{} = game, user_id) do
    case existing_notebook(game.id, user_id) do
      nil -> %{"general" => ""}
      saved -> Map.put(saved.player_notes || %{}, "general", saved.body || "")
    end
  end

  def get_notebook(%MafiaGame{} = game, user_id), do: notebook(game, user_id)

  @doc "Saves a private notebook after removing keys that are not players in this game."
  def save_notebook(%MafiaGame{} = game, user_id, notes) when is_map(notes) do
    with :ok <- WriteGate.ensure_enabled(),
         :ok <- ensure_notebook_user(game, user_id) do
      allowed_ids = MapSet.new(player_ids(game.id))
      notes = stringify_map_keys(notes)
      body = notes |> Map.get("general", "") |> clean_text(20_000)

      player_notes =
        notes
        |> Map.delete("general")
        |> Enum.reduce(%{}, fn {player_id, value}, acc ->
          value = clean_text(value, 5_000)

          if MapSet.member?(allowed_ids, player_id) and value != "" do
            Map.put(acc, player_id, value)
          else
            acc
          end
        end)

      case existing_notebook(game.id, user_id) do
        nil ->
          MafiaNotebook
          |> Ash.Changeset.for_create(:create, %{
            mafia_game_id: game.id,
            user_id: user_id,
            body: body,
            player_notes: player_notes
          })
          |> Ash.create(authorize?: false)

        saved ->
          saved
          |> Ash.Changeset.for_update(:update, %{body: body, player_notes: player_notes})
          |> Ash.update(authorize?: false)
      end
    end
  end

  @doc "Creates a phase-scoped private chat using the current chat limits and capabilities."
  def create_side_chat(%MafiaGame{} = game, creator_user_id, member_user_ids, title \\ nil) do
    rules = GameRules.normalize(game.ruleset)
    member_user_ids = member_user_ids |> List.wrap() |> Enum.map(&to_string/1) |> Enum.uniq()

    with :ok <- WriteGate.ensure_enabled(),
         true <- game.status in [:day, :night] || {:error, :game_not_active},
         true <-
           GameRules.private_chat_allowed?(rules, game.status) ||
             {:error, :private_chat_closed},
         {:ok, creator} <- fetch_player(game.id, creator_user_id),
         :ok <- ensure_capability(game, creator, "private_chat"),
         :ok <- ensure_side_chat_cap(game, creator_user_id, rules),
         {:ok, member_ids} <-
           validate_side_chat_members(game, creator_user_id, member_user_ids, rules) do
      include_moderator? = rules["private_chat_include_moderator"]

      members =
        if include_moderator?, do: Enum.uniq([game.host_id | member_ids]), else: member_ids

      Chat.create_group_conversation(creator_user_id, members,
        kind: :game,
        game_id: game.id,
        admin_ids: if(include_moderator?, do: [game.host_id], else: []),
        title: clean_optional_text(title, 120) || "#{game_label(game)} — Private chat",
        metadata: %{
          "mafia_game_id" => game.id,
          "moderator_id" => game.host_id,
          "channel" => "side_chat",
          "phase_number" => game.phase_number,
          "created_by" => creator_user_id,
          "participant_ids" => member_ids
        }
      )
    else
      false -> {:error, :private_chat_closed}
      {:error, _reason} = error -> error
    end
  end

  # ============================================================================
  # Internal guards / helpers
  # ============================================================================

  defp archive_game_conversations(conversations, host_id) do
    Enum.reduce_while(conversations, :ok, fn conversation, :ok ->
      case Chat.archive_conversation(conversation.id, host_id) do
        {:ok, _archived} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp destroy_game(game) do
    case Ash.destroy(game, authorize?: false) do
      :ok -> :ok
      {:ok, _game} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_players_loaded(%MafiaGame{players: %Ash.NotLoaded{}} = game),
    do: Ash.load!(game, :players, authorize?: false)

  defp ensure_players_loaded(%MafiaGame{} = game), do: game

  defp ensure_setup_game(%MafiaGame{status: :setup}), do: :ok
  defp ensure_setup_game(%MafiaGame{}), do: {:error, :game_already_started}

  defp validate_startable(%MafiaGame{players: players, ruleset: ruleset}) do
    rules = GameRules.normalize(ruleset)

    configured_factions? =
      is_list(Map.get(ruleset || %{}, "factions")) and
        not rules["_legacy_unconfigured_alignments"]

    active = Enum.filter(players, &(GameRules.player_status(&1) == "active"))
    aligned = Enum.filter(active, &(is_binary(&1.alignment) and &1.alignment != ""))
    configured = MapSet.new(GameRules.factions(rules), &faction_key(&1["key"]))
    mafia = Enum.count(aligned, &(faction_key(&1.alignment) == "mafia"))
    town = Enum.count(aligned, &(faction_key(&1.alignment) == "town"))
    min_players = rules["min_players"]
    max_players = rules["max_players"]

    cond do
      length(active) < min_players and min_players == 3 ->
        {:error, :need_at_least_3_players}

      length(active) < min_players ->
        {:error, :need_more_players}

      max_players > 0 and length(active) > max_players ->
        {:error, :too_many_players}

      length(aligned) != length(active) ->
        {:error, :all_players_need_a_role}

      configured_factions? and
          Enum.any?(aligned, &(not MapSet.member?(configured, faction_key(&1.alignment)))) ->
        {:error, :players_need_configured_factions}

      rules["win_mode"] == "classic" and
          Enum.any?(aligned, &(faction_key(&1.alignment) not in ["town", "mafia"])) ->
        {:error, :classic_requires_town_and_mafia}

      rules["win_mode"] == "classic" and mafia < 1 ->
        {:error, :need_at_least_one_mafia}

      rules["win_mode"] == "classic" and town < 1 ->
        {:error, :need_at_least_one_town}

      true ->
        :ok
    end
  end

  defp ensure_rules_compatible(%MafiaGame{status: :setup}, _rules), do: :ok

  defp ensure_rules_compatible(%MafiaGame{} = game, %{"win_mode" => "classic"}) do
    players =
      MafiaPlayer
      |> Ash.Query.filter(mafia_game_id == ^game.id and status == "active")
      |> Ash.read!(authorize?: false)

    if Enum.all?(players, &(faction_key(&1.alignment) in ["town", "mafia"])),
      do: :ok,
      else: {:error, :classic_requires_town_and_mafia}
  end

  defp ensure_rules_compatible(_game, _rules), do: :ok

  defp ensure_player_update_compatible(game, player, attrs) do
    rules = GameRules.normalize(game.ruleset)
    status = Map.get(attrs, :status, GameRules.player_status(player))
    alignment = Map.get(attrs, :alignment, player.alignment)

    if rules["win_mode"] == "classic" and status == "active" and
         faction_key(alignment) not in ["town", "mafia"],
       do: {:error, :classic_requires_town_and_mafia},
       else: :ok
  end

  defp reconcile_legacy_alignment_compatibility(%MafiaGame{} = game, rules) do
    raw_rules = stringify_map_keys(game.ruleset || %{})
    current = GameRules.normalize(raw_rules)

    if is_list(raw_rules["factions"]) and not current["_legacy_unconfigured_alignments"] do
      rules
    else
      configured_keys = MapSet.new(GameRules.factions(rules), &faction_key(&1["key"]))

      unresolved_alignment? =
        MafiaPlayer
        |> Ash.Query.filter(mafia_game_id == ^game.id)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.alignment)
        |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
        |> Enum.any?(&(not MapSet.member?(configured_keys, faction_key(&1))))

      Map.put(rules, "_legacy_unconfigured_alignments", unresolved_alignment?)
    end
  end

  defp resolve_configuration_victory(%MafiaGame{status: status} = game)
       when status in [:day, :night] do
    case maybe_finish(game) do
      {:finished, resolved} -> {:ok, resolved}
      {:continue, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_configuration_victory(%MafiaGame{} = game), do: {:ok, game}

  defp provision_day_thread(game) do
    Chat.create_group_conversation(game.host_id, Enum.map(game.players, & &1.user_id),
      kind: :game,
      game_id: game.id,
      title: "#{game_label(game)} — Town Square",
      metadata: %{
        "mafia_game_id" => game.id,
        "moderator_id" => game.host_id,
        "channel" => "day_thread"
      }
    )
  end

  defp provision_private_faction_chats(game) do
    rules = GameRules.normalize(game.ruleset)
    factions = Enum.reject(GameRules.factions(rules), &(&1["chat_policy"] == "disabled"))

    Enum.reduce_while(factions, {:ok, %{}}, fn faction, {:ok, conversations} ->
      key = faction["key"]

      member_ids =
        game.players
        |> Enum.filter(&(faction_key(&1.alignment) == faction_key(key)))
        |> Enum.map(& &1.user_id)

      if member_ids == [] do
        {:cont, {:ok, conversations}}
      else
        case Chat.create_group_conversation(game.host_id, member_ids,
               kind: :game,
               game_id: game.id,
               include_creator?: rules["private_chat_include_moderator"],
               title: "#{game_label(game)} — #{faction["name"]}",
               metadata: %{
                 "mafia_game_id" => game.id,
                 "moderator_id" => game.host_id,
                 "channel" => "faction",
                 "faction" => key
               }
             ) do
          {:ok, conversation} ->
            {:cont, {:ok, Map.put(conversations, key, conversation)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp sync_private_faction_chats(%MafiaGame{status: :setup}), do: :ok

  defp sync_private_faction_chats(%MafiaGame{} = game) do
    rules = GameRules.normalize(game.ruleset)
    factions = Enum.reject(GameRules.factions(rules), &(&1["chat_policy"] == "disabled"))

    players =
      MafiaPlayer
      |> Ash.Query.filter(mafia_game_id == ^game.id)
      |> Ash.read!(authorize?: false)

    existing =
      game.id
      |> Chat.list_game_conversations()
      |> Enum.filter(&(Map.get(&1.metadata || %{}, "channel") == "faction"))

    {existing_by_faction, duplicate_ids} =
      Enum.reduce(existing, {%{}, MapSet.new()}, fn conversation, {by_faction, duplicates} ->
        key = faction_key(Map.get(conversation.metadata || %{}, "faction"))

        if Map.has_key?(by_faction, key) do
          {by_faction, MapSet.put(duplicates, conversation.id)}
        else
          {Map.put(by_faction, key, conversation), duplicates}
        end
      end)

    configured_keys = MapSet.new(factions, &faction_key(&1["key"]))

    archive_result =
      Enum.reduce_while(existing, :ok, fn conversation, :ok ->
        key = faction_key(Map.get(conversation.metadata || %{}, "faction"))

        if MapSet.member?(configured_keys, key) and
             not MapSet.member?(duplicate_ids, conversation.id) do
          {:cont, :ok}
        else
          case Chat.archive_conversation(conversation.id, game.host_id) do
            {:ok, _archived} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
      end)

    faction_result =
      case archive_result do
        :ok ->
          Enum.reduce_while(factions, :ok, fn faction, :ok ->
            key = faction["key"]

            member_ids =
              if game.status not in [:day, :night] or
                   not GameRules.faction_chat_allowed?(rules, key, game.status) do
                []
              else
                players
                |> Enum.filter(fn player ->
                  faction_key(player.alignment) == faction_key(key) and
                    GameRules.capability?(game.ruleset, player, "private_chat")
                end)
                |> Enum.map(& &1.user_id)
              end

            member_ids = maybe_include_moderator(member_ids, game.host_id, rules)

            case Map.get(existing_by_faction, faction_key(key)) do
              nil when member_ids == [] ->
                {:cont, :ok}

              nil ->
                case Chat.create_group_conversation(game.host_id, member_ids,
                       kind: :game,
                       game_id: game.id,
                       include_creator?: rules["private_chat_include_moderator"],
                       title: "#{game_label(game)} — #{faction["name"]}",
                       metadata: %{
                         "mafia_game_id" => game.id,
                         "moderator_id" => game.host_id,
                         "channel" => "faction",
                         "faction" => key
                       }
                     ) do
                  {:ok, conversation} ->
                    case maybe_set_mafia_conversation(game, key, conversation) do
                      :ok -> {:cont, :ok}
                      {:error, reason} -> {:halt, {:error, reason}}
                    end

                  {:error, reason} ->
                    {:halt, {:error, reason}}
                end

              conversation ->
                title = "#{game_label(game)} — #{faction["name"]}"

                with {:ok, _renamed} <-
                       Chat.rename_conversation(conversation.id, game.host_id, title),
                     :ok <-
                       Chat.sync_conversation_members(
                         conversation.id,
                         game.host_id,
                         member_ids,
                         preserve_actor?: false
                       ),
                     :ok <- maybe_set_mafia_conversation(game, key, conversation) do
                  {:cont, :ok}
                else
                  {:error, reason} -> {:halt, {:error, reason}}
                end
            end
          end)

        {:error, _reason} = error ->
          error
      end

    with :ok <- faction_result do
      sync_side_chat_memberships(game, rules, players)
    end
  end

  defp maybe_set_mafia_conversation(game, key, conversation) do
    if faction_key(key) == "mafia" and game.mafia_chat_conversation_id != conversation.id do
      game
      |> Ash.Changeset.for_update(:update, %{mafia_chat_conversation_id: conversation.id})
      |> Ash.update(authorize?: false)
      |> case do
        {:ok, _updated} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp sync_side_chat_memberships(game, rules, players) do
    players_by_user = Map.new(players, &{&1.user_id, &1})

    game.id
    |> Chat.list_game_conversations()
    |> Enum.filter(&(Map.get(&1.metadata || %{}, "channel") == "side_chat"))
    |> Enum.reduce_while(:ok, fn conversation, :ok ->
      metadata = conversation.metadata || %{}

      open? =
        game.status in [:day, :night] and
          Map.get(metadata, "phase_number") == game.phase_number and
          GameRules.private_chat_allowed?(rules, game.status)

      member_ids =
        if open? do
          metadata
          |> Map.get("participant_ids", [])
          |> List.wrap()
          |> Enum.filter(fn user_id ->
            case Map.get(players_by_user, user_id) do
              nil -> false
              player -> GameRules.capability?(game.ruleset, player, "private_chat")
            end
          end)
        else
          []
        end

      member_ids = maybe_include_moderator(member_ids, game.host_id, rules)

      case Chat.sync_conversation_members(conversation.id, game.host_id, member_ids,
             preserve_actor?: false
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_include_moderator(member_ids, host_id, rules) do
    if rules["private_chat_include_moderator"],
      do: Enum.uniq([host_id | member_ids]),
      else: Enum.reject(member_ids, &(&1 == host_id))
  end

  defp game_label(%MafiaGame{title: nil}), do: "Mafia"
  defp game_label(%MafiaGame{title: title}), do: title

  defp update_game(game, attrs) do
    game
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(authorize?: false)
  end

  defp lock_game_for_update(game_id) do
    dumped_id = Ecto.UUID.dump!(game_id)

    case Repo.query("SELECT id FROM mafia_games WHERE id = $1::uuid FOR UPDATE", [dumped_id]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _result} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_host(%MafiaGame{host_id: host_id}, host_id), do: :ok
  defp authorize_host(%MafiaGame{}, _other), do: {:error, :not_host}

  defp ensure_revision(%MafiaGame{rules_revision: revision}, revision), do: :ok
  defp ensure_revision(%MafiaGame{}, _revision), do: {:error, :stale_rules}

  defp create_rule_revision(game, changed_by_id, summary \\ "Initial rules") do
    MafiaRuleRevision
    |> Ash.Changeset.for_create(:create, %{
      mafia_game_id: game.id,
      changed_by_id: changed_by_id,
      revision: game.rules_revision,
      ruleset: GameRules.normalize(game.ruleset),
      summary: clean_text(summary, 500),
      phase_number: game.phase_number,
      status: to_string(game.status)
    })
    |> Ash.create(authorize?: false)
  end

  defp apply_current_chat_rules(%MafiaGame{day_thread_conversation_id: nil}), do: :ok

  defp apply_current_chat_rules(%MafiaGame{status: :night} = game),
    do: set_day_thread_read_only(game, not GameRules.day_thread_open?(game.ruleset, :night))

  defp apply_current_chat_rules(%MafiaGame{} = game),
    do: set_day_thread_read_only(game, false)

  defp sync_player_mutes(%MafiaGame{day_thread_conversation_id: nil}), do: :ok

  defp sync_player_mutes(%MafiaGame{} = game) do
    MafiaPlayer
    |> Ash.Query.filter(mafia_game_id == ^game.id)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce_while(:ok, fn player, :ok ->
      case sync_player_mute(game, player) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp sync_player_mute(%MafiaGame{day_thread_conversation_id: nil}, _player), do: :ok

  defp sync_player_mute(%MafiaGame{} = game, %MafiaPlayer{} = player) do
    muted? = not GameRules.capability?(game.ruleset, player, "post_public")

    case Chat.shadow_mute_member(
           game.day_thread_conversation_id,
           game.host_id,
           player.user_id,
           muted?
         ) do
      {:ok, _membership} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp normalize_player_attrs(attrs) do
    attrs = stringify_map_keys(attrs)
    status = Map.get(attrs, "status")

    if status && status not in GameRules.statuses() do
      {:error, :invalid_player_status}
    else
      normalized =
        %{}
        |> maybe_put(attrs, "role_name", :role_name, &clean_optional_text(&1, 100))
        |> maybe_put(attrs, "alignment", :alignment, &normalize_faction/1)
        |> maybe_put(attrs, "role_pm_body", :role_pm_body, &clean_optional_text(&1, 5_000))
        |> maybe_put(attrs, "status", :status, &to_string/1)
        |> maybe_put(attrs, "tags", :tags, &normalize_tags/1)
        |> maybe_put(
          attrs,
          "capability_overrides",
          :capability_overrides,
          &normalize_capability_overrides/1
        )

      normalized =
        if status do
          Map.put(normalized, :is_alive, status == "active")
        else
          normalized
        end

      {:ok, normalized}
    end
  end

  defp maybe_put(result, attrs, source_key, target_key, fun) do
    if Map.has_key?(attrs, source_key) do
      Map.put(result, target_key, fun.(Map.get(attrs, source_key)))
    else
      result
    end
  end

  defp normalize_tags(tags) when is_binary(tags),
    do: tags |> String.split(",") |> normalize_tags()

  defp normalize_tags(tags) do
    tags
    |> List.wrap()
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase() |> String.slice(0, 60)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(50)
  end

  defp normalize_capability_overrides(overrides) do
    overrides
    |> stringify_map_keys()
    |> Map.take(GameRules.capabilities())
    |> Map.new(fn {key, value} -> {key, value in [true, "true", "1", 1, "on"]} end)
  end

  defp normalize_faction(nil), do: nil
  defp normalize_faction(value), do: clean_optional_text(value, 100)

  defp faction_key(value), do: GameRules.canonical_faction_key(value)

  defp player_username(%MafiaPlayer{user: %Ash.NotLoaded{}}), do: "Player"
  defp player_username(%MafiaPlayer{user: nil}), do: "Player"
  defp player_username(%MafiaPlayer{user: user}), do: user.username || "Player"

  defp existing_notebook(game_id, user_id) do
    MafiaNotebook
    |> Ash.Query.filter(mafia_game_id == ^game_id and user_id == ^user_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp ensure_notebook_user(%MafiaGame{host_id: user_id}, user_id), do: :ok

  defp ensure_notebook_user(%MafiaGame{} = game, user_id) do
    case fetch_player(game.id, user_id) do
      {:ok, _player} -> :ok
      _ -> {:error, :not_a_player}
    end
  end

  defp player_ids(game_id) do
    MafiaPlayer
    |> Ash.Query.filter(mafia_game_id == ^game_id)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end

  defp ensure_side_chat_cap(game, user_id, rules) do
    cap = rules["night_conversation_cap"]

    count =
      user_id
      |> Chat.list_user_conversations()
      |> Enum.count(fn conversation ->
        metadata = conversation.metadata || %{}

        Map.get(metadata, "mafia_game_id") == game.id and
          Map.get(metadata, "channel") == "side_chat" and
          Map.get(metadata, "phase_number") == game.phase_number and
          Map.get(metadata, "created_by") == user_id
      end)

    if count < cap, do: :ok, else: {:error, :private_chat_cap_reached}
  end

  defp validate_side_chat_members(game, creator_user_id, member_user_ids, rules) do
    ids = Enum.uniq([creator_user_id | member_user_ids])

    if length(ids) > rules["private_chat_participant_cap"] do
      {:error, :too_many_chat_participants}
    else
      Enum.reduce_while(ids, {:ok, []}, fn user_id, {:ok, valid_ids} ->
        case fetch_player(game.id, user_id) do
          {:ok, player} ->
            if GameRules.capability?(game.ruleset, player, "private_chat") do
              {:cont, {:ok, [user_id | valid_ids]}}
            else
              {:halt, {:error, :participant_cannot_private_chat}}
            end

          _ ->
            {:halt, {:error, :invalid_chat_participant}}
        end
      end)
      |> case do
        {:ok, valid_ids} -> {:ok, Enum.reverse(valid_ids)}
        error -> error
      end
    end
  end

  defp stringify_map_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp clean_text(nil, _limit), do: ""

  defp clean_text(value, limit),
    do: value |> to_string() |> String.trim() |> String.slice(0, limit)

  defp clean_optional_text(value, limit) do
    case clean_text(value, limit) do
      "" -> nil
      text -> text
    end
  end

  defp phase_deadline(game, ruleset_key) do
    phase = if ruleset_key == "day_length_seconds", do: :day, else: :night
    seconds = GameRules.phase_duration(game.ruleset, phase)

    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.truncate(:second)
  end

  defp schedule_phase_timer(%MafiaGame{phase_ends_at: nil}), do: :ok

  defp schedule_phase_timer(%MafiaGame{} = game) do
    seconds = max(DateTime.diff(game.phase_ends_at, DateTime.utc_now()), 0)

    _ =
      %{mafia_game_id: game.id, phase_number: game.phase_number}
      |> Map.put(:rules_revision, game.rules_revision)
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
    do: GameRules.normalize(ruleset)["reveal_on_death"] != "none"

  defp flip_text(game, player) do
    role = player.role_name || "an unknown role"
    faction = GameRules.faction_name(game.ruleset, player.alignment) || "an unknown faction"

    case GameRules.normalize(game.ruleset)["reveal_on_death"] do
      "alignment" -> "A player has died. They were #{faction}."
      _ -> "A player has died. They were #{role} (#{faction})."
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

  defp existing_vote(game_id, phase_number, ballot_key, voter_player_id) do
    MafiaVote
    |> Ash.Query.filter(
      mafia_game_id == ^game_id and phase_number == ^phase_number and
        ballot_key == ^ballot_key and voter_player_id == ^voter_player_id
    )
    |> Ash.read_one!(authorize?: false)
  end

  defp fetch_open_ballot(%MafiaGame{} = game, ballot_key) do
    case GameRules.ballot(game.ruleset, ballot_key) do
      nil ->
        {:error, :unknown_ballot}

      %{"enabled" => false} ->
        {:error, :ballot_disabled}

      ballot ->
        with :ok <- ensure_phase_open(game, ballot["phase"]) do
          {:ok, ballot}
        end
    end
  end

  defp ensure_phase_open(%MafiaGame{} = game, phase) do
    cond do
      to_string(game.status) != to_string(phase) -> {:error, :ballot_closed}
      is_nil(game.phase_ends_at) -> :ok
      DateTime.compare(DateTime.utc_now(), game.phase_ends_at) == :lt -> :ok
      true -> {:error, :phase_closed}
    end
  end

  defp ensure_ballot_voter(game, voter, ballot) do
    status = GameRules.player_status(voter)

    cond do
      not GameRules.capability?(game.ruleset, voter, "vote") ->
        if status == "dead",
          do: {:error, :dead_players_cannot_vote},
          else: {:error, :cannot_vote}

      status not in ballot["eligible_statuses"] ->
        {:error, :not_eligible_to_vote}

      true ->
        :ok
    end
  end

  defp ensure_ballot_target(_game, _voter, nil, %{"allow_no_result" => true}), do: :ok
  defp ensure_ballot_target(_game, _voter, nil, _ballot), do: {:error, :target_required}

  defp ensure_ballot_target(game, voter, target_player_id, ballot) do
    case fetch_player_by_id(game.id, target_player_id) do
      {:ok, target} ->
        cond do
          not ballot["allow_self"] and target.id == voter.id ->
            {:error, :self_vote_not_allowed}

          GameRules.player_status(target) not in ballot["candidate_statuses"] ->
            {:error, :target_not_eligible}

          not GameRules.capability?(game.ruleset, target, "candidate") ->
            {:error, :target_not_eligible}

          true ->
            :ok
        end

      _ ->
        {:error, :invalid_target}
    end
  end

  defp eligible_vote?(game, vote, ballot) do
    voter = vote.voter
    target = vote.target
    voter_status = GameRules.player_status(voter)

    voter_status in ballot["eligible_statuses"] and
      GameRules.capability?(game.ruleset, voter, "vote") and
      if(is_nil(target),
        do: ballot["allow_no_result"],
        else:
          GameRules.player_status(target) in ballot["candidate_statuses"] and
            GameRules.capability?(game.ruleset, target, "candidate")
      )
  end

  defp eligible_voters(game, ballot) do
    MafiaPlayer
    |> Ash.Query.filter(mafia_game_id == ^game.id)
    |> Ash.Query.load(:user)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(fn player ->
      GameRules.player_status(player) in ballot["eligible_statuses"] and
        GameRules.capability?(game.ruleset, player, "vote")
    end)
  end

  defp elimination_ballot(game) do
    game.ruleset
    |> GameRules.ballots(:day)
    |> Enum.find(&(&1["effect"] == "eliminate"))
  end

  defp empty_totals,
    do: %{tallies: %{}, total: 0, hammer: 1, leader: nil, voters_by_target: %{}, unvoted: []}

  defp ensure_capability(game, player, capability) do
    if GameRules.capability?(game.ruleset, player, capability),
      do: :ok,
      else: {:error, :capability_not_allowed}
  end

  defp ensure_action_target(_game, nil), do: :ok

  defp ensure_action_target(game, target_player_id) do
    case fetch_player_by_id(game.id, target_player_id) do
      {:ok, target} ->
        if GameRules.capability?(game.ruleset, target, "targetable"),
          do: :ok,
          else: {:error, :target_not_eligible}

      _ ->
        {:error, :invalid_target}
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
