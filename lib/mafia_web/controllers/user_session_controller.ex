defmodule MafiaWeb.UserSessionController do
  use MafiaWeb, :controller

  alias Mafia.Accounts

  @login_window :timer.minutes(15)
  @login_ip_limit 20
  @login_identifier_limit 10
  @registration_window :timer.hours(1)
  @registration_ip_limit 5
  @registration_identifier_limit 3

  def create(conn, %{"user" => %{"identifier" => identifier, "password" => password}}) do
    case enforce_limits([
           {"auth:login:ip:#{client_ip(conn)}", @login_window, @login_ip_limit},
           {"auth:login:id:#{digest(identifier)}", @login_window, @login_identifier_limit}
         ]) do
      :ok ->
        case Accounts.authenticate(identifier, password) do
          {:ok, user} ->
            log_in(conn, user)

          {:error, _} ->
            conn
            |> put_flash(:error, "Invalid username/email or password.")
            |> redirect(to: ~p"/users/log-in")
        end

      {:error, retry_after_ms} ->
        rate_limited(conn, retry_after_ms, "Too many sign-in attempts. Please try again later.")
    end
  end

  def register(conn, %{"user" => attrs}) do
    identifier = Map.get(attrs, "email") || Map.get(attrs, "username") || ""

    case enforce_limits([
           {"auth:register:ip:#{client_ip(conn)}", @registration_window, @registration_ip_limit},
           {"auth:register:id:#{digest(identifier)}", @registration_window,
            @registration_identifier_limit}
         ]) do
      :ok ->
        case Accounts.register(attrs) do
          {:ok, user} ->
            log_in(conn, user)

          {:error, message} ->
            conn
            |> put_flash(:error, to_string(message))
            |> redirect(to: ~p"/users/register")
        end

      {:error, retry_after_ms} ->
        rate_limited(conn, retry_after_ms, "Too many sign-up attempts. Please try again later.")
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/")
  end

  defp log_in(conn, user) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> put_flash(:info, "Welcome, #{user.username}.")
    |> redirect(to: ~p"/")
  end

  defp enforce_limits(specs) do
    if rate_limits_enabled?() do
      Enum.reduce_while(specs, :ok, fn {key, window, limit}, :ok ->
        case Mafia.RateLimit.hit(key, window, limit) do
          {:allow, _count} -> {:cont, :ok}
          {:deny, retry_after_ms} -> {:halt, {:error, retry_after_ms}}
        end
      end)
    else
      :ok
    end
  end

  defp rate_limits_enabled? do
    :mafia
    |> Application.get_env(:rate_limit, [])
    |> Keyword.get(:enabled, true)
  end

  defp client_ip(%Plug.Conn{remote_ip: remote_ip}) do
    remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp digest(identifier) do
    identifier
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp rate_limited(conn, retry_after_ms, message) do
    retry_after_seconds = max(1, div(retry_after_ms + 999, 1000))

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
    |> put_status(:too_many_requests)
    |> text(message)
  end
end
