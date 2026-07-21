defmodule MafiaWeb.AuthLive do
  use MafiaWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(
         :page_title,
         if(socket.assigns.live_action == :register, do: "Register", else: "Sign in")
       )
       |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())}
    end
  end

  @impl true
  def render(%{live_action: :register} = assigns) do
    ~H"""
    <section class="mx-auto max-w-md panel">
      <.header>
        Create a Mafia account
        <:subtitle>
          Existing ConquestK accounts are copied during cutover—use sign in if you already have one.
        </:subtitle>
      </.header>

      <form action={~p"/users/register"} method="post" class="space-y-4">
        <input type="hidden" name="_csrf_token" value={@csrf_token} />
        <.input name="user[username]" label="Username" autocomplete="username" required />
        <.input name="user[email]" type="email" label="Email" autocomplete="email" required />
        <.input
          name="user[password]"
          type="password"
          label="Password"
          autocomplete="new-password"
          minlength="12"
          required
        />
        <.input
          name="user[password_confirmation]"
          type="password"
          label="Confirm password"
          autocomplete="new-password"
          minlength="12"
          required
        />
        <.button variant="primary" class="btn btn-primary w-full">Register</.button>
      </form>

      <p class="mt-5 text-center text-sm text-[color:var(--text-muted)]">
        Already registered? <.link navigate={~p"/users/log-in"}>Sign in</.link>
      </p>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <section class="mx-auto max-w-md panel">
      <.header>
        Sign in
        <:subtitle>
          Your copied ConquestK password works here; browser sessions do not transfer.
        </:subtitle>
      </.header>

      <form action={~p"/users/log-in"} method="post" class="space-y-4">
        <input type="hidden" name="_csrf_token" value={@csrf_token} />
        <.input
          name="user[identifier]"
          label="Username or email"
          autocomplete="username"
          required
        />
        <.input
          name="user[password]"
          type="password"
          label="Password"
          autocomplete="current-password"
          required
        />
        <.button variant="primary" class="btn btn-primary w-full">Sign in</.button>
      </form>

      <p class="mt-5 text-center text-sm text-[color:var(--text-muted)]">
        Need an account? <.link navigate={~p"/users/register"}>Register</.link>
      </p>
    </section>
    """
  end
end
