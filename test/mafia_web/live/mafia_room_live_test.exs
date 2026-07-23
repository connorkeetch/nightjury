defmodule MafiaWeb.MafiaRoomLiveTest do
  use MafiaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mafia.{Accounts, Chat, Fixtures, Games}

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  for status <- [:setup, :day, :night, :finished] do
    test "#{status} renders for the host, a player, and a guest", %{conn: conn} do
      context = game_in(unquote(status))
      path = ~p"/mafia/#{context.game.id}"

      {:ok, host_view, host_html} = live(log_in_user(conn, context.host), path)
      assert host_html =~ "Render Test"
      assert has_element?(host_view, "#delete-game")

      player = hd(context.players)
      {:ok, player_view, player_html} = live(log_in_user(conn, player.user), path)
      assert player_html =~ "Render Test"
      refute has_element?(player_view, "#delete-game")

      {:ok, guest_view, guest_html} = live(conn, path)
      assert guest_html =~ "Render Test"
      refute has_element?(guest_view, "#delete-game")
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
    invitee = Fixtures.user_fixture()
    {:ok, game} = Games.create_game(host.id, %{ruleset: %{"lobby_type" => "invite"}})
    {:ok, view, _html} = live(log_in_user(conn, host), ~p"/mafia/#{game.id}")

    view
    |> form(~s|form[phx-submit="add_player"]|, %{name: invitee.email})
    |> render_submit()

    assert has_element?(view, ".status-chip", "1 seated")
  end

  test "starting a game is separate from saving role edits", %{conn: conn} do
    context = game_in(:setup)
    {:ok, view, _html} = live(log_in_user(conn, context.host), ~p"/mafia/#{context.game.id}")

    assert has_element?(
             view,
             "form[phx-submit='assign_roles'] button[type='submit']",
             "Save roles"
           )

    assert has_element?(
             view,
             "form[phx-submit='assign_roles'] button[type='button'][phx-click='start']"
           )
  end

  test "messages creates a group with controls matching each member's role", %{conn: conn} do
    creator = Fixtures.user_fixture()
    member = Fixtures.user_fixture()
    {:ok, messages, _html} = live(log_in_user(conn, creator), ~p"/messages")

    messages
    |> form("#group-chat-form", %{
      "group" => %{"title" => "Weekend crew", "members" => member.username}
    })
    |> render_submit()

    group =
      Enum.find(Chat.list_user_conversations(creator.id), &(&1.title == "Weekend crew"))

    assert group
    assert_redirect(messages, ~p"/messages/#{group.id}")

    {:ok, admin_chat, _html} =
      live(log_in_user(conn, creator), ~p"/messages/#{group.id}")

    assert has_element?(admin_chat, "button[phx-click='delete_conversation']", "Delete chat")
    refute has_element?(admin_chat, "button[phx-click='leave_conversation']")

    {:ok, member_chat, _html} =
      live(log_in_user(conn, member), ~p"/messages/#{group.id}")

    assert has_element?(member_chat, "button[phx-click='leave_conversation']", "Leave group")
    refute has_element?(member_chat, "button[phx-click='delete_conversation']")
  end

  test "chat renders avatars, signatures, quoted replies, and private images", %{conn: conn} do
    author = Fixtures.user_fixture()
    reader = Fixtures.user_fixture()
    outsider = Fixtures.user_fixture()

    assert {:ok, author} =
             Accounts.update_profile(author, %{
               avatar_url: "https://example.com/chat-avatar.png",
               signature: "Trust the vote record."
             })

    assert {:ok, conversation} =
             Chat.create_group_conversation(author.id, [reader.id], title: "Evidence room")

    assert {:ok, original} =
             Chat.send_message(conversation.id, author.id, "Opening claim")

    {:ok, view, _html} =
      live(log_in_user(conn, author), ~p"/messages/#{conversation.id}")

    assert has_element?(
             view,
             "#message-#{original.id} .size-9 > img[src='https://example.com/chat-avatar.png']"
           )

    assert has_element?(view, "#message-#{original.id}", author.signature)

    upload =
      file_input(view, "#message-form", :image, [
        %{
          last_modified: 1_594_171_879_000,
          name: "evidence.png",
          content: @png,
          size: byte_size(@png),
          type: "image/png"
        }
      ])

    assert render_upload(upload, "evidence.png") =~ "100%"

    view
    |> form("#message-form", %{"message" => %{"body" => ""}})
    |> render_submit()

    assert {:ok, messages} = Chat.list_messages(conversation.id, reader.id)
    image_message = List.last(messages)

    assert has_element?(
             view,
             "#message-#{image_message.id} img[src='/messages/#{image_message.id}/image'][alt='evidence.png']"
           )

    view
    |> element("#message-#{original.id} button[phx-click='quote_reply']")
    |> render_click()

    assert has_element?(view, "#reply-preview", "Opening claim")

    view
    |> form("#message-form", %{"message" => %{"body" => "Following up"}})
    |> render_submit()

    assert {:ok, messages} = Chat.list_messages(conversation.id, reader.id)
    reply = List.last(messages)
    assert reply.reply_to_message_id == original.id
    assert has_element?(view, "#message-#{reply.id} blockquote", "Opening claim")

    image_path = ~p"/messages/#{image_message.id}/image"
    member_conn = conn |> log_in_user(reader) |> get(image_path)
    assert response(member_conn, 200) == @png
    assert hd(get_resp_header(member_conn, "content-type")) =~ "image/png"
    assert get_resp_header(member_conn, "cache-control") == ["private, no-store"]

    assert conn |> log_in_user(outsider) |> get(image_path) |> response(404) == "Not found"
    assert conn |> get(image_path) |> redirected_to() == ~p"/users/log-in"
  end

  test "forum renders avatars, signatures, and persisted quote blocks", %{conn: conn} do
    author = Fixtures.user_fixture()
    reader = Fixtures.user_fixture()

    assert {:ok, author} =
             Accounts.update_profile(author, %{
               avatar_url: "https://example.com/forum-avatar.png",
               signature: "Read twice, vote once."
             })

    assert {:ok, topic} =
             Chat.create_forum_topic(author.id, %{
               title: "Postgame review",
               body: "Forum opener"
             })

    assert {:ok, [opening]} = Chat.list_forum_messages(topic.id)
    {:ok, view, _html} = live(log_in_user(conn, reader), ~p"/forums/#{topic.id}")

    assert has_element?(
             view,
             "#message-#{opening.id} .size-9 > img[src='https://example.com/forum-avatar.png']"
           )

    assert has_element?(view, "#message-#{opening.id}", author.signature)

    view
    |> element("#message-#{opening.id} button[phx-click='quote_reply']")
    |> render_click()

    assert has_element?(view, "#forum-reply-preview", "Forum opener")

    view
    |> form("#forum-reply", %{"reply" => %{"body" => "Forum response"}})
    |> render_submit()

    assert {:ok, messages} = Chat.list_forum_messages(topic.id)
    reply = List.last(messages)
    assert reply.reply_to_message_id == opening.id
    assert has_element?(view, "#message-#{reply.id} blockquote", "Forum opener")
  end

  test "your games includes invite and started games with state-aware controls", %{conn: conn} do
    user = Fixtures.user_fixture()

    contexts =
      for status <- [:setup, :day, :night, :finished], into: %{} do
        {status, game_in(status, user)}
      end

    invite_host = Fixtures.user_fixture()

    {:ok, invite_game} =
      Games.create_game(invite_host.id, %{
        title: "Invite table",
        ruleset: %{"lobby_type" => "invite"}
      })

    assert {:ok, _player} = Games.add_player(invite_game, invite_host.id, user.id)
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/mafia")

    for {status, %{game: game}} <- contexts do
      assert has_element?(view, "#your-game-#{game.id}")

      assert has_element?(
               view,
               "#your-game-#{game.id} p.text-xs",
               "#{status |> to_string() |> String.capitalize()} · You moderate"
             )

      assert has_element?(view, "#delete-game-#{game.id}")
      refute has_element?(view, "#leave-game-#{game.id}")
    end

    assert has_element?(
             view,
             "#your-game-#{invite_game.id} p.text-xs",
             "Setup · You play"
           )

    assert has_element?(view, "#leave-game-#{invite_game.id}")
    refute has_element?(view, "#delete-game-#{invite_game.id}")
  end

  defp game_in(status, host \\ Fixtures.user_fixture()) do
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
