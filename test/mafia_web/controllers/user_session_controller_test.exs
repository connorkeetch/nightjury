defmodule MafiaWeb.UserSessionControllerTest do
  use MafiaWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:mafia, :rate_limit)
    Application.put_env(:mafia, :rate_limit, enabled: true)

    on_exit(fn -> Application.put_env(:mafia, :rate_limit, previous) end)
  end

  test "rate limits login by Railway's client IP despite a conflicting forwarded header", %{
    conn: conn
  } do
    key = "auth:login:ip:203.0.113.41"
    assert {:allow, 20} = Mafia.RateLimit.hit(key, :timer.minutes(15), 20, 20)

    conn =
      conn
      |> put_req_header("x-real-ip", "203.0.113.41")
      |> put_req_header("x-forwarded-for", "198.51.100.41")
      |> post(~p"/users/log-in", %{
        "user" => %{"identifier" => "anyone@example.com", "password" => "not-used"}
      })

    assert response(conn, 429) =~ "Too many sign-in attempts"
    assert get_resp_header(conn, "retry-after") != []
  end

  test "rate limits registration by Railway's client IP despite a conflicting forwarded header",
       %{
         conn: conn
       } do
    key = "auth:register:ip:203.0.113.42"
    assert {:allow, 5} = Mafia.RateLimit.hit(key, :timer.hours(1), 5, 5)

    conn =
      conn
      |> put_req_header("x-real-ip", "203.0.113.42")
      |> put_req_header("x-forwarded-for", "198.51.100.42")
      |> post(~p"/users/register", %{
        "user" => %{"email" => "anyone@example.com", "username" => "anyone"}
      })

    assert response(conn, 429) =~ "Too many sign-up attempts"
    assert get_resp_header(conn, "retry-after") != []
  end
end
