defmodule Mafia.GamesTest do
  use Mafia.DataCase

  alias Mafia.{Fixtures, Games, Notifications}

  test "starts Day 1 with dedicated Town and Mafia conversations" do
    %{game: game, host: host} = started_game([:mafia, :town, :town])

    assert game.status == :day
    assert game.phase_number == 1
    assert game.day_thread_conversation_id
    assert game.mafia_chat_conversation_id
    assert Enum.any?(Notifications.list_for_user(host.id), &(&1.type == "mafia_phase"))
  end

  test "a non-host cannot kick a setup player" do
    host = Fixtures.user_fixture()
    other = Fixtures.user_fixture()
    player_user = Fixtures.user_fixture()
    {:ok, game} = Games.create_game(host.id)
    {:ok, player} = Games.join_game(game, player_user.id)

    assert {:error, :not_host} = Games.kick_player(game, player, other.id)
    assert {:ok, _player} = Games.fetch_player(game.id, player_user.id)
  end

  test "majority hammer resolves the day and town wins" do
    %{game: game, players: [mafia, town1, town2]} = started_game([:mafia, :town, :town])

    assert {:ok, _} = Games.cast_vote(game, town1.user.id, mafia.player.id)
    assert {:ok, _} = Games.cast_vote(game, town2.user.id, mafia.player.id)

    finished = Games.get_game!(game.id)
    assert finished.status == :finished
    assert finished.winner_faction == :town
  end

  test "refuses to start an unbalanced roster" do
    host = Fixtures.user_fixture()
    {:ok, game} = Games.create_game(host.id)
    {:ok, _} = Games.join_game(game, Fixtures.user_fixture().id)
    {:ok, _} = Games.join_game(game, Fixtures.user_fixture().id)

    assert {:error, :need_at_least_3_players} = Games.start_game(game, host.id)
  end

  test "deadline resolution lynches the plurality leader" do
    %{game: game, players: [mafia, town1, _town2, _town3]} =
      started_game([:mafia, :town, :town, :town])

    assert {:ok, _} = Games.cast_vote(game, town1.user.id, mafia.player.id)
    assert {:ok, _} = Games.resolve_day(Games.get_game!(game.id))

    refute player_alive?(game.id, mafia.player.id)
    assert Games.get_game!(game.id).status == :finished
  end

  test "day resolution rolls back when its conversation cannot be locked" do
    %{game: game, host: host} = started_game([:mafia, :town, :town, :town])
    remove_day_thread_member!(game, host.id)

    assert {:error, _reason} = Games.resolve_day(game)
    assert Games.get_game!(game.id).status == :day
  end

  test "mafia win on parity" do
    %{game: game, host: host, players: [_mafia, town1, _town2]} =
      started_game([:mafia, :town, :town])

    assert {:ok, _} = Games.eliminate(game, town1.player.id, :modkill, host.id)

    finished = Games.get_game!(game.id)
    assert finished.status == :finished
    assert finished.winner_faction == :mafia
  end

  test "dead players cannot vote" do
    %{game: game, host: host, players: [mafia, _town1, _town2, target]} =
      started_game([:mafia, :town, :town, :town])

    assert {:ok, _} = Games.eliminate(game, target.player.id, :modkill, host.id)
    game = Games.get_game!(game.id)
    assert game.status == :day

    assert {:error, :dead_players_cannot_vote} =
             Games.cast_vote(game, target.user.id, mafia.player.id)
  end

  test "elimination rolls back when the day-thread mute fails" do
    %{game: game, host: host, players: [_mafia, _town1, _town2, target]} =
      started_game([:mafia, :town, :town, :town])

    remove_day_thread_member!(game, target.user.id)

    assert {:error, _reason} = Games.eliminate(game, target.player.id, :modkill, host.id)
    assert player_alive?(game.id, target.player.id)
  end

  test "open and invite lobbies enforce their join rules" do
    host = Fixtures.user_fixture()
    open_user = Fixtures.user_fixture()
    invited_user = Fixtures.user_fixture()

    {:ok, open_game} = Games.create_game(host.id, %{ruleset: %{"lobby_type" => "open"}})
    assert {:ok, _} = Games.join_game(open_game, open_user.id)

    {:ok, invite_game} =
      Games.create_game(host.id, %{ruleset: %{"lobby_type" => "invite"}})

    assert {:error, :invite_only} = Games.join_game(invite_game, invited_user.id)
    assert {:ok, _} = Games.add_player(invite_game, host.id, invited_user.id)
  end

  test "host can add by email but another user cannot add" do
    host = Fixtures.user_fixture()
    invitee = Fixtures.user_fixture()
    other = Fixtures.user_fixture()
    {:ok, game} = Games.create_game(host.id, %{ruleset: %{"lobby_type" => "invite"}})

    assert {:ok, _} = Games.add_player_by_name(game, host.id, invitee.email)
    assert {:error, :user_not_found} = Games.add_player_by_name(game, host.id, "nobody-xyz-123")
    assert {:error, :not_host} = Games.add_player(game, other.id, other.id)
  end

  test "role assignment persists the private message" do
    host = Fixtures.user_fixture()
    player_user = Fixtures.user_fixture()
    {:ok, game} = Games.create_game(host.id)
    {:ok, player} = Games.join_game(game, player_user.id)

    assert :ok =
             Games.assign_roles(game, host.id, [
               %{
                 player_id: player.id,
                 alignment: :town,
                 role_name: "Cop",
                 role_pm_body: "You investigate."
               }
             ])

    assert {:ok, game} = Games.get_game_for_view(game.id)
    assert Enum.find(game.players, &(&1.id == player.id)).role_pm_body == "You investigate."
  end

  test "No Lynch can be hammered when the ruleset allows it" do
    %{game: game, players: [_mafia, town1, town2]} = started_game([:mafia, :town, :town])

    assert {:ok, _} = Games.cast_vote(game, town1.user.id, nil)
    assert {:ok, _} = Games.cast_vote(game, town2.user.id, nil)
    assert Games.get_game!(game.id).status == :night
  end

  test "only the host can delete a game, before or after start" do
    host = Fixtures.user_fixture()
    other = Fixtures.user_fixture()
    {:ok, setup_game} = Games.create_game(host.id)
    {:ok, _} = Games.join_game(setup_game, Fixtures.user_fixture().id)

    assert {:error, :not_host} = Games.delete_game(setup_game, other.id)
    assert :ok = Games.delete_game(setup_game, host.id)
    assert {:error, :not_found} = Games.get_game(setup_game.id)

    %{game: started, host: started_host} = started_game([:mafia, :town, :town])
    assert :ok = Games.delete_game(started, started_host.id)
    assert {:error, :not_found} = Games.get_game(started.id)
  end

  test "write gate blocks mutations during the cutover smoke test" do
    host = Fixtures.user_fixture()
    previous = Application.get_env(:mafia, :writes_enabled)
    Application.put_env(:mafia, :writes_enabled, false)
    on_exit(fn -> Application.put_env(:mafia, :writes_enabled, previous) end)

    assert {:error, :writes_frozen} = Games.create_game(host.id)
  end

  test "write gate blocks notification mutations during the cutover smoke test" do
    user = Fixtures.user_fixture()
    game_id = Ecto.UUID.generate()
    assert {:ok, 1} = Notifications.notify_mafia_phase([user.id], game_id, "Day 1", "Go")
    [notification] = Notifications.list_for_user(user.id)

    previous = Application.get_env(:mafia, :writes_enabled)
    Application.put_env(:mafia, :writes_enabled, false)
    on_exit(fn -> Application.put_env(:mafia, :writes_enabled, previous) end)

    assert {:error, :writes_frozen} =
             Notifications.notify_mafia_phase([user.id], game_id, "Night 1", "Sleep")

    assert {:error, :writes_frozen} = Notifications.mark_read(notification.id, user.id)
    assert {:error, :writes_frozen} = Notifications.mark_all_read(user.id)
  end

  defp started_game(alignments) do
    host = Fixtures.user_fixture()
    {:ok, game} = Games.create_game(host.id, %{title: "Test Game"})

    players =
      Enum.map(alignments, fn alignment ->
        user = Fixtures.user_fixture()
        {:ok, player} = Games.join_game(game, user.id)
        %{user: user, player: player, alignment: alignment}
      end)

    assignments =
      Enum.map(players, fn player ->
        %{
          player_id: player.player.id,
          alignment: player.alignment,
          role_name: to_string(player.alignment)
        }
      end)

    :ok = Games.assign_roles(game, host.id, assignments)
    {:ok, game} = Games.start_game(game, host.id)
    %{host: host, game: game, players: players}
  end

  defp player_alive?(game_id, player_id) do
    {:ok, game} = Games.get_game_for_view(game_id)
    Enum.find(game.players, &(&1.id == player_id)).is_alive
  end

  defp remove_day_thread_member!(game, user_id) do
    {1, _} =
      Repo.delete_all(
        from(member in "conversation_members",
          where:
            member.conversation_id == type(^game.day_thread_conversation_id, Ecto.UUID) and
              member.user_id == type(^user_id, Ecto.UUID)
        )
      )

    :ok
  end
end
