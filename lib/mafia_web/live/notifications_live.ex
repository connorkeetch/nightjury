defmodule MafiaWeb.NotificationsLive do
  use MafiaWeb, :live_view

  alias Mafia.Notifications

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Notifications.subscribe(socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(:page_title, "Notifications")
     |> load_notifications()}
  end

  @impl true
  def handle_event("mark_read", %{"id" => id}, socket) do
    _ = Notifications.mark_read(id, socket.assigns.current_user.id)
    {:noreply, load_notifications(socket)}
  end

  def handle_event("mark_all_read", _params, socket) do
    _ = Notifications.mark_all_read(socket.assigns.current_user.id)
    {:noreply, load_notifications(socket)}
  end

  @impl true
  def handle_info(:notifications_changed, socket), do: {:noreply, load_notifications(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto max-w-3xl">
      <.header>
        Notifications
        <:actions>
          <.button :if={Enum.any?(@notifications, &is_nil(&1.read_at))} phx-click="mark_all_read">
            Mark all read
          </.button>
        </:actions>
      </.header>

      <div :if={@notifications == []} class="empty-state">
        <div>
          <span class="empty-state-icon" aria-hidden="true">
            <.icon name="hero-bell-slash" class="size-6" />
          </span>
          <p class="font-semibold text-[color:var(--text)]">Nothing needs your attention</p>
          <p class="mt-1 text-sm">Phase updates and mentions will appear here.</p>
        </div>
      </div>

      <div class="space-y-3">
        <article
          :for={notification <- @notifications}
          class={[
            "panel",
            is_nil(notification.read_at) && "border-[color:rgba(201,104,82,0.58)]"
          ]}
        >
          <div class="flex items-start justify-between gap-4">
            <div>
              <div class="flex flex-wrap items-center gap-2">
                <p class="font-semibold">{notification.title}</p>
                <span :if={is_nil(notification.read_at)} class="status-chip status-chip-wax">Unread</span>
              </div>
              <p :if={notification.body} class="mt-1 text-sm text-[color:var(--text-muted)]">
                {notification.body}
              </p>
              <time
                :if={notification.created_at}
                datetime={DateTime.to_iso8601(notification.created_at)}
                class="mono mt-2 block text-xs text-[color:var(--text-muted)]"
              >
                {Calendar.strftime(notification.created_at, "%b %-d, %H:%M")}
              </time>
              <.link
                :if={notification.metadata["mafia_game_id"]}
                navigate={~p"/mafia/#{notification.metadata["mafia_game_id"]}"}
                class="mt-2 inline-block text-sm"
              >
                Open game
              </.link>
            </div>
            <button
              :if={is_nil(notification.read_at)}
              type="button"
              phx-click="mark_read"
              phx-value-id={notification.id}
              class="btn btn-quiet shrink-0 text-sm"
            >
              Mark read
            </button>
          </div>
        </article>
      </div>
    </section>
    """
  end

  defp load_notifications(socket) do
    assign(
      socket,
      :notifications,
      Notifications.list_for_user(socket.assigns.current_user.id)
    )
  end
end
