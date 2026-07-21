defmodule Mafia.AccountsDomain do
  @moduledoc false

  use Ash.Domain

  resources do
    resource(Mafia.Accounts.Resources.User)
  end
end
