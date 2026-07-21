defmodule MafiaWeb.SiteSmokeTest do
  use MafiaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mafia.Fixtures

  test "guest can browse the lobby and reach standalone sign in", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "play-by-post game of hidden roles"
    assert has_element?(view, "a[href='/users/log-in']", "Log in")
    refute has_element?(view, "#mafia-create-form")
  end

  test "copied user can open their profile and host from the lobby", %{conn: conn} do
    user = Fixtures.user_fixture()
    conn = init_test_session(conn, %{"user_id" => user.id})

    {:ok, profile, _html} = live(conn, ~p"/profile")
    assert has_element?(profile, "#profile-form")

    {:ok, lobby, _html} = live(conn, ~p"/")
    assert has_element?(lobby, "#mafia-create-form")

    lobby
    |> form("#mafia-create-form", %{title: "Night Shift", lobby_type: "open"})
    |> render_submit()

    assert_redirect(lobby)
  end
end
