defmodule Mafia.Repo.Migrations.AddHideFromLeaderboardsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :hide_from_leaderboards, :boolean, null: false, default: false
    end
  end
end
