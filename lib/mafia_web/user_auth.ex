defmodule MafiaWeb.UserAuth do
  @moduledoc false

  import Phoenix.Controller
  import Plug.Conn

  alias Mafia.Accounts

  def fetch_current_user(conn, _opts) do
    Plug.Conn.assign(conn, :current_user, Accounts.get_user(get_session(conn, :user_id)))
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Sign in to continue.")
      |> redirect(to: "/users/log-in")
      |> halt()
    end
  end

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont,
     Phoenix.Component.assign(socket, :current_user, Accounts.get_user(session["user_id"]))}
  end

  def on_mount(:require_authenticated_user, params, session, socket) do
    case on_mount(:mount_current_user, params, session, socket) do
      {:cont, %{assigns: %{current_user: nil}} = socket} ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Sign in to continue.")
         |> Phoenix.LiveView.redirect(to: "/users/log-in")}

      {:cont, socket} ->
        {:cont, socket}
    end
  end

  def on_mount(:write_gate, _params, _session, socket) do
    socket =
      Phoenix.LiveView.attach_hook(socket, :write_gate, :handle_event, fn _event,
                                                                          _params,
                                                                          socket ->
        if Mafia.WriteGate.enabled?() do
          {:cont, socket}
        else
          {:halt,
           Phoenix.LiveView.put_flash(
             socket,
             :error,
             "Mafia is read-only while the data move is being verified."
           )}
        end
      end)

    {:cont, socket}
  end
end
