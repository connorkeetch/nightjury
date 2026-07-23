defmodule MafiaWeb.ChatLive do
  use MafiaWeb, :live_view

  alias Mafia.Chat

  @impl true
  def mount(%{"conversation_id" => id}, _session, socket) do
    if connected?(socket), do: Chat.subscribe(id)

    {:ok,
     socket
     |> assign(:conversation_id, id)
     |> assign(:message, "")
     |> assign(:reply_to_message_id, nil)
     |> assign(:gif_url, "")
     |> allow_upload(:image,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 1,
       max_file_size: Chat.image_max_bytes()
     )
     |> refresh()}
  end

  @impl true
  def handle_event("send_message", %{"message" => attrs}, socket) do
    body = Map.get(attrs, "body", "")
    gif_url = Map.get(attrs, "gif_url", "")

    with :ok <- validate_gif_url(gif_url),
         {:ok, attachments} <- consume_image(socket),
         {:ok, _message} <-
           Chat.send_message(socket.assigns.conversation_id, socket.assigns.current_user.id, body,
             reply_to_message_id: socket.assigns.reply_to_message_id,
             attachments: attachments,
             gif_url: gif_url
           ) do
      {:noreply,
       socket
       |> assign(:message, "")
       |> assign(:reply_to_message_id, nil)
       |> assign(:gif_url, "")
       |> refresh()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:message, body)
         |> assign(:gif_url, gif_url)
         |> put_flash(:error, chat_error(reason))}
    end
  end

  def handle_event("validate_message", %{"message" => attrs}, socket) do
    {:noreply,
     socket
     |> assign(:message, Map.get(attrs, "body", ""))
     |> assign(:gif_url, Map.get(attrs, "gif_url", ""))}
  end

  def handle_event("quote_reply", %{"message-id" => message_id}, socket) do
    if Map.has_key?(socket.assigns.message_lookup, message_id) do
      {:noreply, assign(socket, :reply_to_message_id, message_id)}
    else
      {:noreply, put_flash(socket, :error, chat_error(:reply_not_found))}
    end
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply, assign(socket, :reply_to_message_id, nil)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :image, ref)}
  end

  def handle_event("react", %{"message-id" => message_id, "emoji" => emoji}, socket) do
    case Chat.toggle_reaction(message_id, socket.assigns.current_user.id, emoji) do
      {:ok, _} -> {:noreply, refresh(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, chat_error(reason))}
    end
  end

  def handle_event("leave_conversation", _params, socket) do
    case Chat.leave_group_conversation(
           socket.assigns.conversation_id,
           socket.assigns.current_user.id
         ) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "You left the group chat.")
         |> push_navigate(to: ~p"/messages")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, chat_error(reason))}
    end
  end

  def handle_event("delete_conversation", _params, socket) do
    case Chat.delete_group_conversation(
           socket.assigns.conversation_id,
           socket.assigns.current_user.id
         ) do
      {:ok, _conversation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Chat deleted.")
         |> push_navigate(to: ~p"/messages")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, chat_error(reason))}
    end
  end

  def handle_event("hide_conversation", _params, socket) do
    case Chat.hide_direct_conversation(
           socket.assigns.conversation_id,
           socket.assigns.current_user.id
         ) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Chat removed from your list.")
         |> push_navigate(to: ~p"/messages")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, chat_error(reason))}
    end
  end

  @impl true
  def handle_info(:messages_changed, socket), do: {:noreply, refresh(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto flex max-w-4xl flex-col gap-4">
      <header class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="flex min-w-0 items-center gap-3">
          <.link navigate={~p"/messages"} class="btn btn-quiet" aria-label="Back to messages">
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>

          <div class="min-w-0">
            <p class="eyebrow">Conversation</p>

            <h1 class="section-heading mt-1 truncate">{@conversation.title || "Mafia chat"}</h1>

            <p :if={@conversation.is_read_only} class="text-sm text-[color:var(--warning-text)]">
              This thread is locked until the next day phase.
            </p>
          </div>
        </div>

        <div
          :if={standalone_group?(@conversation) or direct?(@conversation)}
          class="flex shrink-0 flex-wrap gap-2"
        >
          <button
            :if={
              standalone_group?(@conversation) and
                !conversation_admin?(@conversation, @current_user.id)
            }
            type="button"
            phx-click="leave_conversation"
            data-confirm="Leave this group chat? You won't be able to reopen it."
            class="btn btn-secondary text-sm"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Leave group
          </button>

          <button
            :if={
              standalone_group?(@conversation) and
                conversation_admin?(@conversation, @current_user.id)
            }
            type="button"
            phx-click="delete_conversation"
            data-confirm="Remove this chat from everyone's list? Members won't be able to reopen it."
            class="btn btn-quiet text-sm hover:text-[color:var(--color-danger-text)]"
          >
            <.icon name="hero-trash" class="size-4" /> Delete chat
          </button>

          <button
            :if={direct?(@conversation)}
            type="button"
            phx-click="hide_conversation"
            data-confirm="Remove this private chat from your list? It will return if either person starts it again."
            class="btn btn-quiet text-sm hover:text-[color:var(--color-danger-text)]"
          >
            <.icon name="hero-trash" class="size-4" /> Delete chat
          </button>
        </div>
      </header>

      <div id="messages" class="panel min-h-80 space-y-5">
        <div :if={@messages == []} class="empty-state min-h-64 border-0 bg-transparent">
          <div>
            <span class="empty-state-icon" aria-hidden="true">
              <.icon name="hero-chat-bubble-bottom-center-text" class="size-6" />
            </span>

            <p class="font-semibold text-[color:var(--text)]">The floor is open.</p>

            <p class="mt-1 text-sm">No messages yet.</p>
          </div>
        </div>

        <article
          :for={message <- @messages}
          id={"message-#{message.id}"}
          class="group border-b border-[color:var(--border)] pb-5 last:border-0 last:pb-0"
        >
          <div class="flex items-start gap-3">
            <.user_avatar user={message.user} class="size-9 text-xs" />
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-baseline gap-2">
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

              <blockquote
                :if={quoted = Map.get(@message_lookup, message.reply_to_message_id)}
                class="mt-2 rounded-md border-l-2 border-[color:var(--border-strong)] bg-[color:var(--surface-2)] px-3 py-2 text-sm text-[color:var(--text-muted)]"
              >
                <p class="font-medium text-[color:var(--text)]">{quoted.user.username}</p>

                <p class="line-clamp-2 whitespace-pre-wrap">{quoted_body(quoted)}</p>
              </blockquote>

              <.message_body
                message={message}
                class={[
                  "mt-1",
                  system_message?(message) && "italic text-[color:var(--text-muted)]"
                ]}
              />

              <img
                :if={attachment = image_attachment(message)}
                src={~p"/messages/#{message.id}/image"}
                alt={attachment["name"] || "Attached image"}
                class="mt-3 max-h-96 max-w-full rounded-lg border border-[color:var(--border)] object-contain"
                loading="lazy"
                decoding="async"
              />
              <p
                :if={message.user.signature && !system_message?(message)}
                class="mt-3 whitespace-pre-wrap border-t border-[color:var(--border)] pt-2 text-xs text-[color:var(--text-muted)]"
              >
                {message.user.signature}
              </p>

              <div class="mt-2 flex flex-wrap gap-1">
                <.message_reactions message={message} current_user={@current_user} />
                <button
                  type="button"
                  phx-click="quote_reply"
                  phx-value-message-id={message.id}
                  class="min-h-9 rounded-full border border-[color:var(--border)] px-3 text-xs"
                  aria-label={"Reply to #{message.user.username}"}
                >
                  <.icon name="hero-arrow-uturn-left" class="size-3.5" /> Reply
                </button>
              </div>
            </div>
          </div>
        </article>
      </div>

      <.form
        for={
          to_form(
            %{
              "body" => @message,
              "gif_url" => @gif_url,
              "reply_to_message_id" => @reply_to_message_id || ""
            },
            as: :message
          )
        }
        id="message-form"
        phx-change="validate_message"
        phx-submit="send_message"
        class="space-y-3"
      >
        <div
          :if={quoted = Map.get(@message_lookup, @reply_to_message_id)}
          id="reply-preview"
          class="flex items-start justify-between gap-3 rounded-lg border border-[color:var(--border)] bg-[color:var(--surface-2)] px-3 py-2 text-sm"
        >
          <div class="min-w-0">
            <p class="font-medium">Replying to {quoted.user.username}</p>

            <p class="line-clamp-2 whitespace-pre-wrap text-[color:var(--text-muted)]">
              {quoted_body(quoted)}
            </p>
          </div>

          <button
            type="button"
            phx-click="cancel_reply"
            class="min-h-9 min-w-9 rounded-md"
            aria-label="Cancel reply"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div
          :for={entry <- @uploads.image.entries}
          class="flex items-center gap-3 rounded-lg border border-[color:var(--border)] p-2"
        >
          <.live_img_preview entry={entry} class="size-16 rounded-md object-cover" />
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm">{entry.client_name}</p>

            <progress value={entry.progress} max="100" class="h-1 w-full">
              {entry.progress}%
            </progress>

            <p
              :for={error <- upload_errors(@uploads.image, entry)}
              class="text-xs text-[color:var(--color-danger-text)]"
            >
              {upload_error(error)}
            </p>
          </div>

          <button
            type="button"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            class="min-h-9 min-w-9 rounded-md"
            aria-label="Remove image"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <p
          :for={error <- upload_errors(@uploads.image)}
          class="text-sm text-[color:var(--color-danger-text)]"
        >
          {upload_error(error)}
        </p>

        <input
          type="hidden"
          name="message[reply_to_message_id]"
          value={@reply_to_message_id || ""}
        />
        <.rich_text_input
          id="message-body"
          name="message[body]"
          value={@message}
          label="Message"
          rows={4}
          maxlength="10000"
          gif_name="message[gif_url]"
          gif_value={@gif_url}
          placeholder={
            if @conversation.is_read_only, do: "Thread is read-only", else: "Write a message…"
          }
          disabled={@conversation.is_read_only}
        />
        <div class="flex flex-wrap items-center justify-between gap-2">
          <label class={[
            "btn btn-secondary cursor-pointer",
            @conversation.is_read_only && "pointer-events-none opacity-50"
          ]}>
            <.icon name="hero-photo" class="size-4" /> <span>Image</span>
            <.live_file_input
              upload={@uploads.image}
              class="sr-only"
              disabled={@conversation.is_read_only}
            />
          </label>
          <.button
            variant="primary"
            disabled={@conversation.is_read_only}
            phx-disable-with="Sending…"
          >
            <.icon name="hero-paper-airplane" class="size-4" /> Send
          </.button>
        </div>
        <p class="text-xs text-[color:var(--text-muted)]">
          One JPEG, PNG, or WebP image · 2 MB maximum
        </p>
      </.form>
    </section>
    """
  end

  defp refresh(socket) do
    user_id = socket.assigns.current_user.id
    id = socket.assigns.conversation_id

    with {:ok, conversation} <- Chat.get_conversation_for_user(id, user_id),
         {:ok, messages} <- Chat.list_messages(id, user_id) do
      socket
      |> assign(:page_title, conversation.title || "Messages")
      |> assign(:conversation, conversation)
      |> assign(:messages, messages)
      |> assign(:message_lookup, Map.new(messages, &{&1.id, &1}))
    else
      _ ->
        socket
        |> put_flash(:error, "Conversation not found.")
        |> push_navigate(to: ~p"/messages")
    end
  end

  defp consume_image(socket) do
    upload = socket.assigns.uploads.image

    errors =
      upload_errors(upload) ++
        Enum.flat_map(upload.entries, &upload_errors(upload, &1))

    if errors == [] do
      case consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
             result =
               with {:ok, data} <- File.read(path) do
                 Chat.prepare_image_attachment(data, entry.client_name)
               else
                 _ -> {:error, :invalid_image}
               end

             {:ok, result}
           end) do
        [] -> {:ok, []}
        [{:ok, attachment}] -> {:ok, [attachment]}
        [{:error, reason}] -> {:error, reason}
      end
    else
      {:error, :invalid_image}
    end
  end

  defp image_attachment(%{attachments: attachments}) when is_list(attachments),
    do: Enum.find(attachments, &image_attachment?/1)

  defp image_attachment(_message), do: nil

  defp image_attachment?(attachment),
    do:
      attachment["type"] == "image" or
        (is_binary(attachment["id"]) and is_binary(attachment["content_type"]))

  defp quoted_body(%{body: body}) when is_binary(body) and body != "", do: body

  defp quoted_body(%{attachments: attachments}) do
    image? = Enum.any?(attachments, &image_attachment?/1)
    gif? = Enum.any?(attachments, &(&1["type"] == "gif"))

    cond do
      image? and gif? -> "Image and GIF attachments"
      image? -> "Image attachment"
      gif? -> "GIF attachment"
      true -> "Attachment"
    end
  end

  defp validate_gif_url(url) when url in [nil, ""], do: :ok

  defp validate_gif_url(url),
    do: if(Chat.valid_gif_url?(url), do: :ok, else: {:error, :invalid_gif})

  defp system_message?(message), do: (message.json_metadata || %{})["system"] == true

  defp upload_error(:too_large), do: "Keep images under 2 MB."
  defp upload_error(:not_accepted), do: "Choose a JPEG, PNG, or WebP image."
  defp upload_error(:too_many_files), do: "Attach one image at a time."
  defp upload_error(_error), do: "That image could not be uploaded."

  defp standalone_group?(%{kind: :group, game_id: nil, metadata: metadata}),
    do: is_nil(Map.get(metadata || %{}, "mafia_game_id"))

  defp standalone_group?(_conversation), do: false

  defp direct?(%{kind: :direct}), do: true
  defp direct?(_conversation), do: false

  defp conversation_admin?(conversation, user_id),
    do: Enum.any?(conversation.members, &(&1.user_id == user_id and &1.role == :admin))

  defp chat_error(:muted), do: "You cannot post or react after elimination."
  defp chat_error(:read_only), do: "This conversation is read-only."
  defp chat_error(:empty_message), do: "Write a message or attach an image or GIF first."
  defp chat_error(:message_too_long), do: "Keep messages under 10,000 characters."
  defp chat_error(:invalid_gif), do: "Use a direct HTTPS URL ending in .gif."
  defp chat_error(:reply_not_found), do: "That message is no longer available."
  defp chat_error(:image_too_large), do: "Keep images under 2 MB."
  defp chat_error(:unsupported_image), do: "Choose a JPEG, PNG, or WebP image."
  defp chat_error(:invalid_image), do: "That image could not be uploaded."
  defp chat_error(:image_quota_exceeded), do: "You've reached the 50 MB image limit."
  defp chat_error(:rate_limited), do: "Slow down and try again in a moment."
  defp chat_error(:managed_conversation), do: "Game conversations are managed from the game."
  defp chat_error(:admin_must_delete), do: "Group admins must delete the chat instead."
  defp chat_error(:not_admin), do: "Only a group admin can delete this chat."
  defp chat_error(_), do: "That chat action could not be completed."
end
