defmodule MafiaWeb.ChatComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MafiaWeb.ChatComponents

  test "formatted messages render safe semantic markup and GIFs" do
    html =
      render_component(&ChatComponents.message_body/1,
        message: %{
          body:
            "**bold** *italic* ++underline++ ~~strike~~\n- first\n- second\n> quoted\n[link](https://example.com) <script>alert(1)</script>",
          json_metadata: %{"format" => "simple_markup_v1"},
          attachments: [%{"type" => "gif", "url" => "https://cdn.example.com/reaction.gif"}]
        }
      )

    assert html =~ "<strong>bold</strong>"
    assert html =~ "<em>italic</em>"
    assert html =~ "<u>underline</u>"
    assert html =~ "<s>strike</s>"
    assert html =~ "<ul><li>first</li><li>second</li></ul>"
    assert html =~ "<blockquote>quoted</blockquote>"
    assert html =~ ~s(href="https://example.com")
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script>"
    assert html =~ ~s(src="https://cdn.example.com/reaction.gif")
  end

  test "legacy messages stay literal and unsafe media is not rendered" do
    html =
      render_component(&ChatComponents.message_body/1,
        message: %{
          body: "**still literal** [bad](javascript:alert(1))",
          json_metadata: %{},
          attachments: [%{"type" => "gif", "url" => "javascript:alert(1)"}]
        }
      )

    assert html =~ "**still literal**"
    refute html =~ "<strong>"
    refute html =~ "<img"
  end

  test "forum guests can see reaction counts without active controls" do
    html =
      render_component(&ChatComponents.message_reactions/1,
        message: %{
          id: Ecto.UUID.generate(),
          reactions: [%{emoji: "👍", user_id: Ecto.UUID.generate()}]
        },
        current_user: nil
      )

    assert html =~ "👍 1"
    refute html =~ "phx-click"
    refute html =~ "Add a reaction"
  end
end
