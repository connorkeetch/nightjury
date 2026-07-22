defmodule Mafia.Repo.Migrations.AddConfigurableGameplay do
  use Ecto.Migration

  @import_constraints [
    {:mafia_rule_revisions, :mafia_rule_revisions_mafia_game_id_fkey},
    {:mafia_rule_revisions, :mafia_rule_revisions_changed_by_id_fkey},
    {:mafia_notebooks, :mafia_notebooks_mafia_game_id_fkey},
    {:mafia_notebooks, :mafia_notebooks_user_id_fkey}
  ]

  def up do
    alter table(:mafia_games) do
      add :rules_revision, :bigint, null: false, default: 1
    end

    alter table(:mafia_players) do
      add :status, :text, null: false, default: "active"
      add :tags, {:array, :text}, null: false, default: []
      add :capability_overrides, :map, null: false, default: %{}
    end

    execute("UPDATE mafia_players SET status = CASE WHEN is_alive THEN 'active' ELSE 'dead' END")

    create constraint(:mafia_players, :mafia_players_valid_status,
             check: "status IN ('active', 'dead', 'removed', 'spectator')"
           )

    drop_if_exists unique_index(:mafia_votes, [:mafia_game_id, :phase_number, :voter_player_id],
                     name: :mafia_votes_one_vote_per_phase_index
                   )

    alter table(:mafia_votes) do
      add :ballot_key, :text, null: false, default: "elimination"
    end

    create unique_index(
             :mafia_votes,
             [:mafia_game_id, :phase_number, :ballot_key, :voter_player_id],
             name: :mafia_votes_one_vote_per_ballot_index
           )

    create index(:mafia_votes, [:mafia_game_id, :phase_number, :ballot_key, :target_player_id],
             name: :mafia_votes_tally_index
           )

    create table(:mafia_rule_revisions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :mafia_game_id,
          references(:mafia_games, type: :uuid, on_delete: :delete_all),
          null: false

      add :changed_by_id,
          references(:users, type: :uuid, on_delete: :nothing),
          null: false

      add :revision, :bigint, null: false
      add :ruleset, :map, null: false
      add :summary, :text, null: false, default: ""
      add :phase_number, :bigint, null: false, default: 0
      add :status, :text, null: false, default: "setup"
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:mafia_rule_revisions, [:mafia_game_id, :revision],
             name: :mafia_rule_revisions_unique_game_revision_index
           )

    create table(:mafia_notebooks, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :mafia_game_id,
          references(:mafia_games, type: :uuid, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :uuid, on_delete: :delete_all),
          null: false

      add :body, :text, null: false, default: ""
      add :player_notes, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:mafia_notebooks, [:mafia_game_id, :user_id],
             name: :mafia_notebooks_unique_game_user_index
           )

    Enum.each(@import_constraints, fn {table, constraint} ->
      execute(
        "ALTER TABLE #{table} ALTER CONSTRAINT #{constraint} " <>
          "DEFERRABLE INITIALLY DEFERRED"
      )
    end)

    execute("""
    UPDATE conversations
    SET game_id = (metadata->>'mafia_game_id')::uuid
    WHERE game_id IS NULL
      AND metadata ? 'mafia_game_id'
      AND metadata->>'mafia_game_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    """)
  end

  def down do
    drop table(:mafia_notebooks)
    drop table(:mafia_rule_revisions)

    # The legacy schema allows one vote per phase, so custom-ballot votes cannot
    # survive a rollback without violating the index restored below.
    execute("DELETE FROM mafia_votes WHERE ballot_key <> 'elimination'")

    drop_if_exists index(
                     :mafia_votes,
                     [:mafia_game_id, :phase_number, :ballot_key, :target_player_id],
                     name: :mafia_votes_tally_index
                   )

    drop_if_exists unique_index(
                     :mafia_votes,
                     [:mafia_game_id, :phase_number, :ballot_key, :voter_player_id],
                     name: :mafia_votes_one_vote_per_ballot_index
                   )

    alter table(:mafia_votes) do
      remove :ballot_key
    end

    create unique_index(:mafia_votes, [:mafia_game_id, :phase_number, :voter_player_id],
             name: :mafia_votes_one_vote_per_phase_index
           )

    drop constraint(:mafia_players, :mafia_players_valid_status)

    alter table(:mafia_players) do
      remove :status
      remove :tags
      remove :capability_overrides
    end

    alter table(:mafia_games) do
      remove :rules_revision
    end
  end
end
