defmodule Mafia.AccountsTest do
  use Mafia.DataCase, async: true

  alias Mafia.Accounts
  alias Mafia.Fixtures

  test "registers, authenticates, and updates a lightweight profile" do
    user =
      Fixtures.user_fixture(%{
        username: "ModeratorOne",
        password: "StrongPassword123!",
        password_confirmation: "StrongPassword123!"
      })

    assert {:ok, authenticated} =
             Accounts.authenticate("moderatorone", "StrongPassword123!")

    assert authenticated.id == user.id

    assert {:ok, updated} =
             Accounts.update_profile(user, %{
               bio: "Runs patient games.",
               tagline: "Trust no one",
               avatar_url: "https://example.com/avatar.png"
             })

    assert updated.bio == "Runs patient games."
    assert Accounts.get_user_by_username("MODERATORONE").id == user.id
  end

  test "rejects a wrong password" do
    user = Fixtures.user_fixture()
    assert {:error, :invalid_login} = Accounts.authenticate(user.email, "wrong password")
  end

  test "searches usernames by case-insensitive prefix" do
    matches = ~w(connor connie conman cory coke)
    Enum.each(matches, &Fixtures.user_fixture(%{username: &1}))
    Fixtures.user_fixture(%{username: "scout"})

    assert Accounts.search_users(" CO ")
           |> Enum.map(& &1.username)
           |> Enum.sort() == Enum.sort(matches)

    assert Accounts.search_users("  ") == []
  end
end
