defmodule MafiaWeb.ConnCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MafiaWeb.Endpoint

      use MafiaWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import MafiaWeb.ConnCase
    end
  end

  setup tags do
    Mafia.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
