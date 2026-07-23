defmodule MafiaWeb.GameWorkspaceLiveTest do
  use MafiaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mafia.{Fixtures, Games}

  test "public rulebook and moderator settings share the game workspace", %{conn: conn} do
    host = Fixtures.user_fixture()
    {:ok, game} = Games.create_game(host.id, %{title: "Rulebook Test"})

    {:ok, rules, rules_html} = live(conn, ~p"/mafia/#{game.id}/rules")
    assert rules_html =~ "Rulebook Test rules"
    assert rules_html =~ "Mafia: Night phases only"
    assert has_element?(rules, "nav[aria-label='Game workspace']", "Overview")

    {:ok, settings, _html} =
      conn
      |> log_in_user(host)
      |> live(~p"/mafia/#{game.id}/settings")

    assert has_element?(settings, "#game-settings-form")

    settings
    |> element("button[phx-click='add_ballot']")
    |> render_click()

    assert has_element?(settings, "h3", "New ballot")

    settings
    |> element("button[phx-click='add_faction']")
    |> render_click()

    assert has_element?(settings, "input[value='New faction']")

    assert has_element?(
             settings,
             "select[name='rules[factions][2][chat_policy]'] option[value='always']",
             "Always open (24/7)"
           )
  end

  test "player notebook is roster-backed and private to its owner", %{conn: conn} do
    host = Fixtures.user_fixture()
    player = Fixtures.user_fixture()
    other_player = Fixtures.user_fixture()
    {:ok, game} = Games.create_game(host.id, %{title: "Notebook Test"})
    {:ok, _seat} = Games.join_game(game, player.id)
    {:ok, _seat} = Games.join_game(game, other_player.id)

    {:ok, notebook, _html} =
      conn
      |> log_in_user(player)
      |> live(~p"/mafia/#{game.id}/notes")

    assert has_element?(notebook, "#game-notebook-form")
    other_seat = Enum.find(game_with_players(game).players, &(&1.user_id == other_player.id))

    assert has_element?(
             notebook,
             "textarea[name='notes[players][#{other_seat.id}]']"
           )

    notebook
    |> form("#game-notebook-form", %{notes: %{general: "Track the second ballot."}})
    |> render_change()

    assert Games.notebook(game, player.id)["general"] == "Track the second ballot."
    assert Games.notebook(game, other_player.id)["general"] == ""
  end

  defp log_in_user(conn, user), do: init_test_session(conn, %{"user_id" => user.id})

  defp game_with_players(game) do
    {:ok, loaded} = Games.get_game_for_view(game.id)
    loaded
  end
end
