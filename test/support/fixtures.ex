defmodule Mafia.Fixtures do
  @moduledoc false

  alias Mafia.Accounts

  def user_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive, :monotonic])

    params =
      Map.merge(
        %{
          username: "player#{unique}",
          email: "player#{unique}@test.com",
          password: "StrongPassword#{unique}!",
          password_confirmation: "StrongPassword#{unique}!"
        },
        attrs
      )

    {:ok, user} = Accounts.register(params)
    user
  end
end
