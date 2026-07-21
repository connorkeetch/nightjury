defmodule MafiaWeb.HealthControllerTest do
  use MafiaWeb.ConnCase, async: true

  test "reports that the service is available", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert %{"status" => "ok"} = json_response(conn, 200)
  end
end
