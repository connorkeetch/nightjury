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
      <p class="eyebrow mb-4">Enter the chamber</p>
      <.header>
        Create a Night Jury account
        <:subtitle>
          New to Night Jury? Choose a name the table will recognize.
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
        <.button
          variant="primary"
          class="btn btn-primary w-full"
          phx-disable-with="Creating account…"
        >
          Register
        </.button>
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
      <p class="eyebrow mb-4">Return to the table</p>
      <.header>
        Sign in
        <:subtitle>
          Use your existing username or email and password. Browser sessions do not transfer.
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
        <.button
          variant="primary"
          class="btn btn-primary w-full"
          phx-disable-with="Signing in…"
        >
          Sign in
        </.button>
      </form>

      <p class="mt-5 text-center text-sm text-[color:var(--text-muted)]">
        Need an account? <.link navigate={~p"/users/register"}>Register</.link>
      </p>
    </section>
    """
  end
end
