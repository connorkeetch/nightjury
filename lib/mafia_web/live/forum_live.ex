defmodule MafiaWeb.ForumLive do
  use MafiaWeb, :live_view

  alias Mafia.Chat

  @impl true
  def mount(%{"id" => id}, _session, socket), do: mount_topic(id, socket)
  def mount(%{"topic_id" => id}, _session, socket), do: mount_topic(id, socket)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Forums")
     |> assign(:topic, nil)
     |> assign(:topics, Chat.list_forum_topics())
     |> assign(:messages, [])
     |> assign(:topic_form, topic_form())
     |> assign(:reply_form, reply_form())}
  end

  @impl true
  def handle_event("create_topic", _params, %{assigns: %{current_user: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "Sign in to start a topic.")}
  end

  def handle_event("create_topic", %{"topic" => attrs}, socket) do
    case Chat.create_forum_topic(socket.assigns.current_user.id, attrs) do
      {:ok, topic} ->
        {:noreply, push_navigate(socket, to: "/forums/#{topic.id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:topic_form, to_form(attrs, as: :topic))
         |> put_flash(:error, forum_error(reason))}
    end
  end

  def handle_event("reply", _params, %{assigns: %{current_user: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "Sign in to reply.")}
  end

  def handle_event("reply", %{"reply" => %{"body" => body} = attrs}, socket) do
    case Chat.reply_to_forum_topic(socket.assigns.topic.id, socket.assigns.current_user.id, body) do
      {:ok, _message} ->
        {:noreply, socket |> assign(:reply_form, reply_form()) |> refresh_topic()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:reply_form, to_form(attrs, as: :reply))
         |> put_flash(:error, forum_error(reason))}
    end
  end

  def handle_event("react", _params, %{assigns: %{current_user: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "Sign in to react.")}
  end

  def handle_event("react", %{"message-id" => message_id, "emoji" => emoji}, socket) do
    case Chat.toggle_forum_reaction(message_id, socket.assigns.current_user.id, emoji) do
      {:ok, _result} -> {:noreply, refresh_topic(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, forum_error(reason))}
    end
  end

  @impl true
  def handle_info(:messages_changed, socket), do: {:noreply, refresh_topic(socket)}

  @impl true
  def render(%{topic: nil} = assigns) do
    ~H"""
    <section class="mx-auto max-w-4xl space-y-6">
      <.header>
        Forums
        <:subtitle>
          Talk strategy, revisit verdicts, and compare notes outside active games.
        </:subtitle>
      </.header>

      <div :if={@current_user} class="panel">
        <p class="eyebrow">Open a discussion</p>
        <.form for={@topic_form} id="new-forum-topic" phx-submit="create_topic" class="mt-4 space-y-4">
          <.input
            field={@topic_form[:title]}
            label="Topic title"
            maxlength="160"
            required
          />
          <.input
            field={@topic_form[:body]}
            type="textarea"
            label="Opening post"
            rows="6"
            maxlength="10000"
            required
          />
          <.button variant="primary" phx-disable-with="Posting…">
            <.icon name="hero-plus" class="size-4" /> Start topic
          </.button>
        </.form>
      </div>

      <div :if={!@current_user} class="panel flex items-center justify-between gap-4">
        <p class="text-sm text-[color:var(--text-muted)]">Anyone can read. Sign in to post.</p>
        <.button navigate={~p"/users/log-in"}>Sign in</.button>
      </div>

      <div :if={@topics == []} class="empty-state">
        <div>
          <span class="empty-state-icon" aria-hidden="true">
            <.icon name="hero-chat-bubble-left-right" class="size-6" />
          </span>
          <p class="font-semibold text-[color:var(--text)]">No discussions yet</p>
          <p class="mt-1 text-sm">Start the first post-game conversation.</p>
        </div>
      </div>

      <div class="space-y-3">
        <.link
          :for={topic <- @topics}
          navigate={"/forums/#{topic.id}"}
          class="panel panel-interactive flex items-center justify-between gap-4 no-underline"
        >
          <div class="min-w-0">
            <p class="truncate font-semibold text-[color:var(--text)]">{topic.title}</p>
            <p class="mt-1 text-sm text-[color:var(--text-muted)]">
              Started by {topic.creator.username} · {Calendar.strftime(topic.created_at, "%b %-d, %Y")}
            </p>
          </div>
          <.icon name="hero-chevron-right" class="size-5 shrink-0 text-[color:var(--text-muted)]" />
        </.link>
      </div>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <section class="mx-auto flex max-w-4xl flex-col gap-4">
      <header class="flex items-start gap-3">
        <.link navigate="/forums" class="btn btn-quiet" aria-label="Back to forums">
          <.icon name="hero-arrow-left" class="size-4" />
        </.link>
        <div class="min-w-0">
          <p class="eyebrow">Forum topic</p>
          <h1 class="section-heading mt-1">{@topic.title}</h1>
          <p class="mt-2 text-sm text-[color:var(--text-muted)]">
            Started by {@topic.creator.username}
          </p>
          <p :if={@topic.is_read_only} class="mt-2 text-sm text-[color:var(--warning-text)]">
            This topic is read-only.
          </p>
        </div>
      </header>

      <div id="forum-messages" class="panel min-h-80 space-y-5">
        <article
          :for={message <- @messages}
          id={"message-#{message.id}"}
          class="border-b border-[color:var(--border)] pb-5 last:border-0 last:pb-0"
        >
          <div class="flex items-baseline gap-2">
            <.link
              navigate={~p"/users/#{message.user.username}"}
              class="font-semibold text-[color:var(--text)]"
            >
              {message.user.username}
            </.link>
            <time
              datetime={DateTime.to_iso8601(message.created_at)}
              class="mono text-xs text-[color:var(--text-muted)]"
            >
              {Calendar.strftime(message.created_at, "%b %-d, %H:%M")}
            </time>
          </div>
          <p class="mt-1 whitespace-pre-wrap leading-6">{message.body}</p>
          <div :if={@current_user} class="mt-2 flex flex-wrap gap-1">
            <button
              :for={emoji <- Chat.allowed_reactions()}
              type="button"
              phx-click="react"
              phx-value-message-id={message.id}
              phx-value-emoji={emoji}
              class={[
                "min-h-9 rounded-full border border-[color:var(--border)] px-2 text-xs",
                reacted?(message, @current_user.id, emoji) && "bg-[color:var(--surface-2)]"
              ]}
              aria-label={"React with #{emoji}; #{reaction_count(message, emoji)} reactions"}
              aria-pressed={reacted?(message, @current_user.id, emoji)}
            >
              {emoji} {reaction_count(message, emoji)}
            </button>
          </div>
        </article>
      </div>

      <.form
        :if={@current_user}
        for={@reply_form}
        id="forum-reply"
        phx-submit="reply"
        class="space-y-3"
      >
        <.input
          field={@reply_form[:body]}
          type="textarea"
          label="Reply"
          rows="5"
          maxlength="10000"
          placeholder={
            if @topic.is_read_only, do: "Topic is read-only", else: "Add to the discussion…"
          }
          disabled={@topic.is_read_only}
          required
        />
        <.button
          variant="primary"
          disabled={@topic.is_read_only}
          phx-disable-with="Posting…"
        >
          <.icon name="hero-paper-airplane" class="size-4" /> Post reply
        </.button>
      </.form>

      <div :if={!@current_user} class="panel flex items-center justify-between gap-4">
        <p class="text-sm text-[color:var(--text-muted)]">Sign in to reply or react.</p>
        <.button navigate={~p"/users/log-in"}>Sign in</.button>
      </div>
    </section>
    """
  end

  defp mount_topic(id, socket) do
    case load_topic(socket, id) do
      {:ok, socket} ->
        if connected?(socket), do: Chat.subscribe(id)
        {:ok, socket}

      {:error, socket} ->
        {:ok,
         socket
         |> put_flash(:error, "Forum topic not found.")
         |> push_navigate(to: "/forums")}
    end
  end

  defp refresh_topic(socket) do
    case load_topic(socket, socket.assigns.topic.id) do
      {:ok, socket} ->
        socket

      {:error, socket} ->
        socket |> put_flash(:error, "Forum topic not found.") |> push_navigate(to: "/forums")
    end
  end

  defp load_topic(socket, id) do
    with {:ok, topic} <- Chat.get_forum_topic(id),
         {:ok, messages} <- Chat.list_forum_messages(id) do
      {:ok,
       socket
       |> assign(:page_title, topic.title)
       |> assign(:topic, topic)
       |> assign(:topics, [])
       |> assign(:messages, messages)
       |> assign(:topic_form, topic_form())
       |> assign(:reply_form, reply_form())}
    else
      _ ->
        {:error,
         socket
         |> assign(:page_title, "Forums")
         |> assign(:topic, nil)
         |> assign(:topics, [])
         |> assign(:messages, [])
         |> assign(:topic_form, topic_form())
         |> assign(:reply_form, reply_form())}
    end
  end

  defp topic_form(attrs \\ %{"title" => "", "body" => ""}),
    do: to_form(attrs, as: :topic)

  defp reply_form(attrs \\ %{"body" => ""}), do: to_form(attrs, as: :reply)

  defp reacted?(message, user_id, emoji),
    do: Enum.any?(message.reactions, &(&1.user_id == user_id and &1.emoji == emoji))

  defp reaction_count(message, emoji), do: Enum.count(message.reactions, &(&1.emoji == emoji))

  defp forum_error(:empty_title), do: "Add a topic title."
  defp forum_error(:title_too_long), do: "Keep the title under 160 characters."
  defp forum_error(:empty_message), do: "Write a message first."
  defp forum_error(:message_too_long), do: "Keep posts under 10,000 characters."
  defp forum_error(:read_only), do: "This topic is read-only."
  defp forum_error(:muted), do: "You cannot post or react right now."
  defp forum_error(:rate_limited), do: "Slow down and try again in a moment."
  defp forum_error(_reason), do: "That forum action could not be completed."
end
