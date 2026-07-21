defmodule Mafia.Repo.Migrations.InstallOban do
  use Ecto.Migration

  def up, do: Oban.Migration.up(prefix: "public")
  def down, do: Oban.Migration.down(prefix: "public")
end
