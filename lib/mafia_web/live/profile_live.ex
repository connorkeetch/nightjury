defmodule MafiaWeb.ProfileLive do
  use MafiaWeb, :live_view

  alias Mafia.Accounts

  @impl true
  def mount(params, _session, socket) do
    case socket.assigns.live_action do
      :edit ->
        user = socket.assigns.current_user

        {:ok,
         socket
         |> assign(:page_title, "Profile")
         |> assign(:profile_user, user)
         |> assign_form(user)}

      :show ->
        case Accounts.get_user_by_username(params["username"]) do
          nil ->
            {:ok,
             socket
             |> put_flash(:error, "Profile not found.")
             |> push_navigate(to: ~p"/")}

          user ->
            {:ok,
             socket
             |> assign(:page_title, user.username)
             |> assign(:profile_user, user)}
        end
    end
  end

  @impl true
  def handle_event("save_profile", %{"profile" => attrs}, socket) do
    case Accounts.update_profile(socket.assigns.current_user, attrs) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Profile updated.")
         |> assign(:current_user, user)
         |> assign(:profile_user, user)
         |> assign_form(user)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, profile_error(error))}
    end
  end

  @impl true
  def render(%{live_action: :edit} = assigns) do
    ~H"""
    <section class="mx-auto max-w-2xl panel">
      <p class="eyebrow mb-4">Your calling card</p>
      <.header>
        Your profile
        <:subtitle>This lightweight profile belongs to the Night Jury community.</:subtitle>
      </.header>

      <div class="mb-6 flex items-center gap-4">
        <.avatar user={@profile_user} />
        <div>
          <p class="text-lg font-semibold">{@profile_user.username}</p>

          <.link navigate={~p"/users/#{@profile_user.username}"} class="text-sm">
            View public profile
          </.link>
        </div>
      </div>

      <.form for={@form} id="profile-form" phx-submit="save_profile" class="space-y-4">
        <.input field={@form[:tagline]} label="Tagline" maxlength="255" />
        <.input field={@form[:bio]} type="textarea" label="Bio" rows="6" maxlength="500" />
        <.input field={@form[:avatar_url]} type="url" label="Avatar URL" />
        <.button variant="primary">Save profile</.button>
      </.form>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <section class="mx-auto max-w-2xl panel">
      <p class="eyebrow mb-5">Night Jury member</p>
      <div class="flex items-start gap-5">
        <.avatar user={@profile_user} />
        <div class="min-w-0">
          <h1 class="text-2xl font-semibold">{@profile_user.username}</h1>

          <p :if={@profile_user.tagline} class="mt-1 text-[color:var(--text-muted)]">
            {@profile_user.tagline}
          </p>

          <p :if={@profile_user.bio} class="mt-5 whitespace-pre-wrap leading-7">
            {@profile_user.bio}
          </p>

          <p :if={!@profile_user.bio} class="mt-5 text-[color:var(--text-muted)]">
            No bio yet.
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr :user, :map, required: true

  defp avatar(assigns) do
    ~H"""
    <div class="grid size-20 shrink-0 place-items-center overflow-hidden rounded-full border border-[color:var(--border)] bg-[color:var(--surface-2)] text-2xl font-semibold">
      <img
        :if={@user.avatar_url}
        src={@user.avatar_url}
        alt=""
        class="size-full object-cover"
        referrerpolicy="no-referrer"
      /> <span :if={!@user.avatar_url}>{@user.username |> String.first() |> String.upcase()}</span>
    </div>
    """
  end

  defp assign_form(socket, user) do
    assign(
      socket,
      :form,
      to_form(%{"bio" => user.bio, "tagline" => user.tagline, "avatar_url" => user.avatar_url},
        as: :profile
      )
    )
  end

  defp profile_error(error) do
    Exception.message(error)
  rescue
    _ -> "Could not update profile."
  end
end
