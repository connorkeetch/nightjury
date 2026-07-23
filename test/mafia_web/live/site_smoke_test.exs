defmodule MafiaWeb.SiteSmokeTest do
  use MafiaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mafia.{Chat, Fixtures}

  test "guest can browse the lobby and reach standalone sign in", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "play-by-post game of hidden roles"
    assert has_element?(view, "nav a[href='/']", "Night Jury")
    assert has_element?(view, "a[href='/users/log-in']", "Log in")
    refute has_element?(view, "#mafia-create-form")

    {:ok, login, login_html} = live(conn, ~p"/users/log-in")
    assert has_element?(login, "nav a[href='/']", "Night Jury")
    assert login_html =~ "Username or email"
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

  test "user starts a direct chat by exact username", %{conn: conn} do
    sender = Fixtures.user_fixture()
    recipient = Fixtures.user_fixture(%{username: "connor"})
    Fixtures.user_fixture(%{username: "connie"})
    Fixtures.user_fixture(%{username: "scout"})

    {:ok, messages, _html} =
      conn
      |> init_test_session(%{"user_id" => sender.id})
      |> live(~p"/messages")

    assert has_element?(messages, "#start-chat-form")

    messages
    |> form("#start-chat-form", %{chat: %{username: "co"}})
    |> render_change()

    assert has_element?(
             messages,
             "#start-chat-form input[name='chat[username]'][list='chat-user-suggestions']"
           )

    assert has_element?(messages, "#chat-user-suggestions option[value='connor']")
    assert has_element?(messages, "#chat-user-suggestions option[value='connie']")
    refute has_element?(messages, "#chat-user-suggestions option[value='scout']")

    assert messages
           |> form("#start-chat-form", %{chat: %{username: sender.username}})
           |> render_submit() =~ "Choose someone other than yourself."

    assert messages
           |> form("#start-chat-form", %{chat: %{username: "definitely_missing_user"}})
           |> render_submit() =~ "No active user has that exact username."

    messages
    |> form("#start-chat-form", %{chat: %{username: recipient.username}})
    |> render_submit()

    assert_redirect(messages)

    assert [%{kind: :direct} = conversation] = Chat.list_user_conversations(sender.id)
    assert Enum.any?(Chat.list_user_conversations(recipient.id), &(&1.id == conversation.id))
  end
end
