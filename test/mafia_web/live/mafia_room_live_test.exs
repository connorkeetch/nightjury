defmodule MafiaWeb.MafiaRoomLiveTest do
  use MafiaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mafia.{Fixtures, Games}

  for status <- [:setup, :day, :night, :finished] do
    test "#{status} renders for the host, a player, and a guest", %{conn: conn} do
      context = game_in(unquote(status))
      path = ~p"/mafia/#{context.game.id}"

      {:ok, _view, host_html} = live(log_in_user(conn, context.host), path)
      assert host_html =~ "Render Test"

      player = hd(context.players)
      {:ok, _view, player_html} = live(log_in_user(conn, player.user), path)
      assert player_html =~ "Render Test"

      {:ok, _view, guest_html} = live(conn, path)
      assert guest_html =~ "Render Test"
    end
  end

  test "a player can join an open setup game", %{conn: conn} do
    context = game_in(:setup)
    newcomer = Fixtures.user_fixture()
    {:ok, view, _html} = live(log_in_user(conn, newcomer), ~p"/mafia/#{context.game.id}")

    view |> element("button[phx-click='join']") |> render_click()
    assert has_element?(view, "button[phx-click='leave']", "Leave")
  end

  test "host sees moderator controls during the day", %{conn: conn} do
    context = game_in(:day)
    {:ok, view, _html} = live(log_in_user(conn, context.host), ~p"/mafia/#{context.game.id}")

    assert has_element?(view, "h2", "Moderator controls")
  end

  test "invite lobby hides self-join from a visitor", %{conn: conn} do
    host = Fixtures.user_fixture()
    visitor = Fixtures.user_fixture()
    {:ok, game} = Games.create_game(host.id, %{ruleset: %{"lobby_type" => "invite"}})
    {:ok, view, html} = live(log_in_user(conn, visitor), ~p"/mafia/#{game.id}")

    assert html =~ "Invite only"
    assert html =~ "No players on file. The moderator is accepting names."
    refute has_element?(view, "button[phx-click='join']")
  end

  test "host adds a player by name", %{conn: conn} do
    host = Fixtures.user_fixture()
    invitee = Fixtures.user_fixture(%{username: "connor"})
    Fixtures.user_fixture(%{username: "connie"})
    {:ok, game} = Games.create_game(host.id, %{ruleset: %{"lobby_type" => "invite"}})
    {:ok, view, _html} = live(log_in_user(conn, host), ~p"/mafia/#{game.id}")

    view
    |> form(~s|form[phx-submit="add_player"]|, %{name: "co"})
    |> render_change()

    assert has_element?(view, "#player-name[list='player-user-suggestions']")
    assert has_element?(view, "#player-user-suggestions option[value='connor']")
    assert has_element?(view, "#player-user-suggestions option[value='connie']")

    view
    |> form(~s|form[phx-submit="add_player"]|, %{name: invitee.email})
    |> render_submit()

    assert has_element?(view, ".status-chip", "1 seated")
  end

  test "starting a game is separate from saving role edits", %{conn: conn} do
    context = game_in(:setup)
    {:ok, view, _html} = live(log_in_user(conn, context.host), ~p"/mafia/#{context.game.id}")
    first_player_id = hd(context.players).player.id

    assert has_element?(
             view,
             "form[phx-submit='assign_roles'] button[type='submit']",
             "Save roles"
           )

    assert has_element?(
             view,
             "form[phx-submit='assign_roles'] button[type='button'][phx-click='start']"
           )

    assert has_element?(
             view,
             "select[name='roles[#{first_player_id}][alignment]'] option[value='town']",
             "Town"
           )

    assert has_element?(
             view,
             "input[name='roles[#{first_player_id}][role_name]'][list='common-role-presets']"
           )

    assert has_element?(view, "datalist#common-role-presets option[value='Doctor']")
  end

  defp game_in(status) do
    host = Fixtures.user_fixture()
    {:ok, game} = Games.create_game(host.id, %{title: "Render Test"})

    players =
      for alignment <- [:mafia, :town, :town] do
        user = Fixtures.user_fixture()
        {:ok, player} = Games.join_game(game, user.id)
        %{user: user, player: player, alignment: alignment}
      end

    context = %{host: host, game: game, players: players}

    case status do
      :setup ->
        context

      _ ->
        assignments =
          Enum.map(players, fn player ->
            %{
              player_id: player.player.id,
              alignment: player.alignment,
              role_name: "role"
            }
          end)

        :ok = Games.assign_roles(game, host.id, assignments)
        {:ok, game} = Games.start_game(game, host.id)
        advance(%{context | game: game}, status)
    end
  end

  defp advance(context, :day), do: context

  defp advance(context, :night) do
    {:ok, game} = Games.resolve_day(context.game)
    %{context | game: game}
  end

  defp advance(context, :finished) do
    [mafia, town1, town2] = context.players
    {:ok, _} = Games.cast_vote(context.game, town1.user.id, mafia.player.id)
    {:ok, _} = Games.cast_vote(context.game, town2.user.id, mafia.player.id)
    %{context | game: Games.get_game!(context.game.id)}
  end

  defp log_in_user(conn, user), do: init_test_session(conn, %{"user_id" => user.id})
end
