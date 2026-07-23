defmodule MafiaWeb.ChatComponents do
  @moduledoc "Shared, safe message composition and rendering components."

  use Phoenix.Component

  alias Mafia.Chat
  alias Phoenix.HTML.Form

  import MafiaWeb.CoreComponents, only: [icon: 1]

  @format "simple_markup_v1"
  @emoji_picker ["😀", "😂", "😍", "🤔", "😮", "😢", "😡", "🎉", "👍", "👎", "❤️", "💀"]

  attr :message, :any, required: true
  attr :class, :any, default: nil

  def message_body(assigns) do
    assigns =
      assigns
      |> assign(:formatted?, formatted?(assigns.message))
      |> assign(:gifs, gif_attachments(assigns.message.attachments))

    ~H"""
    <div class={["rich-text", @class]}>
      <%= if @formatted? do %>
        {render_markup(@message.body)}
      <% else %>
        <p class="whitespace-pre-wrap">{@message.body}</p>
      <% end %>
      <img
        :for={gif <- @gifs}
        src={gif["url"]}
        alt="GIF attachment"
        class="rich-text-gif"
        loading="lazy"
        referrerpolicy="no-referrer"
      />
    </div>
    """
  end

  attr :message, :any, required: true
  attr :current_user, :any, default: nil
  attr :event, :string, default: "react"

  def message_reactions(assigns) do
    user_id = assigns.current_user && assigns.current_user.id

    assigns =
      assigns
      |> assign(:user_id, user_id)
      |> assign(:reaction_summary, reaction_summary(assigns.message, user_id))
      |> assign(:allowed_reactions, Chat.allowed_reactions())

    ~H"""
    <div
      :if={@reaction_summary != [] or @current_user}
      class="message-reactions"
      aria-label="Message reactions"
    >
      <%= for reaction <- @reaction_summary do %>
        <button
          :if={@current_user}
          type="button"
          phx-click={@event}
          phx-value-message-id={@message.id}
          phx-value-emoji={reaction.emoji}
          class={["reaction-chip", reaction.reacted? && "reaction-chip-active"]}
          aria-label={reaction_label(reaction)}
          aria-pressed={reaction.reacted?}
        >
          {reaction.emoji} {reaction.count}
        </button>
        <span
          :if={!@current_user}
          class="reaction-chip"
          aria-label={reaction_label(reaction)}
        >
          {reaction.emoji} {reaction.count}
        </span>
      <% end %>

      <details :if={@current_user} class="reaction-picker">
        <summary class="reaction-add" aria-label="Add a reaction" title="Add reaction">
          <.icon name="hero-face-smile" class="size-4" />
          <span aria-hidden="true">+</span>
        </summary>
        <div class="reaction-picker-menu">
          <button
            :for={emoji <- @allowed_reactions}
            type="button"
            phx-click={@event}
            phx-value-message-id={@message.id}
            phx-value-emoji={emoji}
            class="reaction-option"
            aria-label={"React with #{emoji}"}
          >
            {emoji}
          </button>
        </div>
      </details>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :label, :string, default: nil
  attr :rows, :integer, default: 5
  attr :placeholder, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :required, :boolean, default: false
  attr :gif_name, :string, default: nil
  attr :gif_value, :string, default: ""
  attr :rest, :global, include: ~w(maxlength)

  def rich_text_input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(:field, nil)
    |> assign(:id, assigns.id || field.id)
    |> assign(:name, assigns.name || field.name)
    |> assign(:value, if(is_nil(assigns.value), do: field.value, else: assigns.value))
    |> rich_text_input()
  end

  def rich_text_input(assigns) do
    assigns = assign(assigns, :emoji_picker, @emoji_picker)

    ~H"""
    <div id={"#{@id}-editor"} class="rich-editor" phx-hook="RichTextEditor">
      <label :if={@label} for={@id} class="mb-1.5 block text-sm font-medium">{@label}</label>
      <div :if={!@disabled} class="rich-toolbar" role="toolbar" aria-label="Text formatting">
        <button type="button" data-rich-action="bold" aria-label="Bold" title="Bold">
          <strong>B</strong>
        </button>
        <button type="button" data-rich-action="italic" aria-label="Italic" title="Italic">
          <em>I</em>
        </button>
        <button type="button" data-rich-action="underline" aria-label="Underline" title="Underline">
          <u>U</u>
        </button>
        <button
          type="button"
          data-rich-action="strike"
          aria-label="Strikethrough"
          title="Strikethrough"
        >
          <s>S</s>
        </button>
        <span class="rich-toolbar-divider" aria-hidden="true"></span>
        <button
          type="button"
          data-rich-action="bullet-list"
          aria-label="Bullet list"
          title="Bullet list"
        >
          <.icon name="hero-list-bullet" class="size-4" />
        </button>
        <button
          type="button"
          data-rich-action="numbered-list"
          aria-label="Numbered list"
          title="Numbered list"
        >
          <span class="text-xs font-bold">1.</span>
        </button>
        <button type="button" data-rich-action="quote" aria-label="Quote" title="Quote">
          <span class="text-lg leading-none">“</span>
        </button>
        <button type="button" data-rich-action="link" aria-label="Add link" title="Add link">
          <.icon name="hero-link" class="size-4" />
        </button>
        <button
          :if={@gif_name}
          type="button"
          data-rich-action="gif"
          aria-label="Attach GIF"
          title="Attach GIF"
          class="rich-toolbar-gif"
        >
          GIF
        </button>
        <details class="rich-emoji-picker">
          <summary aria-label="Insert emoji" title="Insert emoji">😀</summary>
          <div class="rich-emoji-menu">
            <button
              :for={emoji <- @emoji_picker}
              type="button"
              data-rich-action="insert"
              data-rich-insert={emoji}
              aria-label={"Insert #{emoji}"}
            >
              {emoji}
            </button>
          </div>
        </details>
      </div>
      <textarea
        id={@id}
        name={@name}
        class={["input rich-editor-textarea", @disabled && "rich-editor-textarea-disabled"]}
        rows={@rows}
        placeholder={@placeholder}
        disabled={@disabled}
        required={@required}
        {@rest}
      >{Form.normalize_value("textarea", @value)}</textarea>
      <input
        :if={@gif_name}
        type="hidden"
        name={@gif_name}
        value={@gif_value}
        data-gif-url
      />
      <div :if={@gif_name && !@disabled} class="rich-gif-status" aria-live="polite">
        <span data-gif-status>{if @gif_value in [nil, ""], do: "No GIF attached", else: "GIF attached"}</span>
        <button
          type="button"
          data-rich-action="remove-gif"
          hidden={@gif_value in [nil, ""]}
          data-remove-gif
        >
          Remove
        </button>
      </div>
      <p :if={!@disabled} class="rich-editor-help">
        Format selected text, paste emoji, or attach a direct HTTPS .gif URL.
      </p>
    </div>
    """
  end

  defp formatted?(message) do
    is_map(message.json_metadata) and message.json_metadata["format"] == @format
  end

  defp gif_attachments(attachments) when is_list(attachments) do
    Enum.filter(attachments, fn
      %{"type" => "gif", "url" => url} -> Chat.valid_gif_url?(url)
      _ -> false
    end)
  end

  defp gif_attachments(_), do: []

  defp reaction_summary(message, user_id) do
    for emoji <- Chat.allowed_reactions(),
        matching = Enum.filter(message.reactions, &(&1.emoji == emoji)),
        matching != [] do
      %{
        emoji: emoji,
        count: length(matching),
        reacted?: not is_nil(user_id) and Enum.any?(matching, &(&1.user_id == user_id))
      }
    end
  end

  defp reaction_label(%{emoji: emoji, count: count}) do
    "#{emoji}: #{count} #{if count == 1, do: "reaction", else: "reactions"}"
  end

  defp render_markup(body) do
    body
    |> to_string()
    |> String.split(~r/\r\n|\r|\n/, trim: false)
    |> render_lines()
    |> IO.iodata_to_binary()
    |> Phoenix.HTML.raw()
  end

  defp render_lines([]), do: []

  defp render_lines([line | rest] = lines) do
    cond do
      blank?(line) ->
        ["<br>" | render_lines(rest)]

      list_item(line, :ul) ->
        render_list(lines, :ul)

      list_item(line, :ol) ->
        render_list(lines, :ol)

      quote_line(line) ->
        {quotes, remaining} = Enum.split_while(lines, &quote_line/1)

        content =
          quotes |> Enum.map(&(&1 |> quote_line() |> inline())) |> Enum.intersperse("<br>")

        ["<blockquote>", content, "</blockquote>" | render_lines(remaining)]

      true ->
        {paragraph, remaining} =
          Enum.split_while(lines, fn value ->
            not blank?(value) and is_nil(list_item(value, :ul)) and
              is_nil(list_item(value, :ol)) and is_nil(quote_line(value))
          end)

        content = paragraph |> Enum.map(&inline/1) |> Enum.intersperse("<br>")
        ["<p>", content, "</p>" | render_lines(remaining)]
    end
  end

  defp render_list(lines, type) do
    {items, remaining} = Enum.split_while(lines, &list_item(&1, type))
    tag = Atom.to_string(type)
    rendered = Enum.map(items, &["<li>", &1 |> list_item(type) |> inline(), "</li>"])
    ["<#{tag}>", rendered, "</#{tag}>" | render_lines(remaining)]
  end

  defp inline(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> replace(~r/\*\*([^*\n]+)\*\*/, "<strong>\\1</strong>")
    |> replace(~r/~~([^~\n]+)~~/, "<s>\\1</s>")
    |> replace(~r/\+\+([^+\n]+)\+\+/, "<u>\\1</u>")
    |> replace(~r/(?<!\*)\*([^*\n]+)\*(?!\*)/, "<em>\\1</em>")
    |> replace_links()
  end

  defp replace(text, regex, replacement), do: Regex.replace(regex, text, replacement)

  defp replace_links(text) do
    Regex.replace(~r/\[([^\]\n]+)\]\((https:\/\/[^\s<>)]+)\)/i, text, fn _, label, url ->
      ~s(<a href="#{url}" target="_blank" rel="noopener noreferrer">#{label}</a>)
    end)
  end

  defp list_item(line, :ul) do
    case Regex.run(~r/^\s*[-*]\s+(.+)$/, line) do
      [_, item] -> item
      _ -> nil
    end
  end

  defp list_item(line, :ol) do
    case Regex.run(~r/^\s*\d+[.)]\s+(.+)$/, line) do
      [_, item] -> item
      _ -> nil
    end
  end

  defp quote_line(line) do
    case Regex.run(~r/^\s*>\s?(.*)$/, line) do
      [_, quote] -> quote
      _ -> nil
    end
  end

  defp blank?(line), do: String.trim(line) == ""
end
