defmodule MafiaWeb.HealthController do
  use MafiaWeb, :controller

  def show(conn, _params) do
    case Ecto.Adapters.SQL.query(Mafia.Repo, "SELECT 1", []) do
      {:ok, _result} ->
        json(conn, %{status: "ok"})

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable"})
    end
  end
end
