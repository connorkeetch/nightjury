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

      <div :if={@notifications == []} class="panel text-[color:var(--text-muted)]">
        No notifications yet.
      </div>

      <div class="space-y-3">
        <article
          :for={notification <- @notifications}
          class={[
            "panel",
            is_nil(notification.read_at) && "border-[color:var(--link)]"
          ]}
        >
          <div class="flex items-start justify-between gap-4">
            <div>
              <p class="font-semibold">{notification.title}</p>
              <p :if={notification.body} class="mt-1 text-sm text-[color:var(--text-muted)]">
                {notification.body}
              </p>
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
              class="text-sm text-[color:var(--link)]"
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
