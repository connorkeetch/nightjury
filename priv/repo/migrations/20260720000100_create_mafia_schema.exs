defmodule Mafia.Repo.Migrations.CreateMafiaSchema do
  use Ecto.Migration

  @import_constraints [
    {:users, :users_vip_granted_by_fkey},
    {:user_account_status, :user_account_status_user_id_fkey},
    {:user_account_status, :user_account_status_admin_user_id_fkey},
    {:conversations, :conversations_creator_id_fkey},
    {:conversation_members, :conversation_members_conversation_id_fkey},
    {:conversation_members, :conversation_members_user_id_fkey},
    {:messages, :messages_conversation_id_fkey},
    {:messages, :messages_user_id_fkey},
    {:messages, :messages_reply_to_message_id_fkey},
    {:message_reactions, :message_reactions_message_id_fkey},
    {:message_reactions, :message_reactions_user_id_fkey},
    {:mafia_games, :mafia_games_host_id_fkey},
    {:mafia_players, :mafia_players_mafia_game_id_fkey},
    {:mafia_players, :mafia_players_user_id_fkey},
    {:mafia_votes, :mafia_votes_mafia_game_id_fkey},
    {:mafia_votes, :mafia_votes_voter_player_id_fkey},
    {:mafia_votes, :mafia_votes_target_player_id_fkey},
    {:mafia_night_actions, :mafia_night_actions_mafia_game_id_fkey},
    {:mafia_night_actions, :mafia_night_actions_actor_player_id_fkey},
    {:mafia_night_actions, :mafia_night_actions_target_player_id_fkey},
    {:notifications, :notifications_user_id_fkey},
    {:notifications, :notifications_related_user_id_fkey}
  ]

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")

    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :username, :text, null: false
      add :email, :text, null: false
      add :hashed_password, :text
      add :authenticated_at, :utc_datetime_usec
      add :is_admin, :boolean, null: false, default: false
      add :is_vip, :boolean, null: false, default: false
      add :premium_tier, :text, null: false, default: "free"
      add :premium_expires_at, :utc_datetime_usec
      add :vip_reason, :text
      add :last_login, :utc_datetime_usec
      add :email_verified, :boolean, null: false, default: false
      add :bio, :text
      add :tagline, :text
      add :avatar_url, :text
      add :skill_rating, :bigint, null: false, default: 850
      add :highest_skill_rating, :bigint, null: false, default: 850
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :vip_granted_by,
          references(:users,
            type: :uuid,
            on_delete: :nothing,
            name: :users_vip_granted_by_fkey
          )

      add :deleted_at, :utc_datetime_usec
    end

    create unique_index(:users, [:email], name: :users_unique_email_index)
    execute("CREATE UNIQUE INDEX users_unique_username_index ON users (lower(username))")

    create table(:user_account_status, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :status, :text, null: false, default: "active"
      add :reason, :text
      add :status_changed_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :expires_at, :utc_datetime_usec

      add :user_id,
          references(:users, type: :uuid, on_delete: :delete_all),
          null: false

      add :admin_user_id,
          references(:users, type: :uuid, on_delete: :nilify_all)
    end

    create index(:user_account_status, [:user_id, :status_changed_at])

    create table(:conversations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :kind, :text, null: false, default: "group"
      add :title, :text
      add :is_archived, :boolean, null: false, default: false
      add :game_id, :uuid
      add :metadata, :map, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")

      add :creator_id,
          references(:users, type: :uuid, on_delete: :nothing),
          null: false

      add :is_read_only, :boolean, null: false, default: false
    end

    create table(:conversation_members, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :role, :text, null: false, default: "member"
      add :last_read_message_id, :uuid
      add :is_muted, :boolean, null: false, default: false
      add :is_pinned, :boolean, null: false, default: false
      add :shadow_muted, :boolean, null: false, default: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")

      add :conversation_id,
          references(:conversations,
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :user_id,
          references(:users, type: :uuid, on_delete: :nothing),
          null: false

      add :hidden_at, :utc_datetime_usec
    end

    create unique_index(:conversation_members, [:conversation_id, :user_id],
             name: :conversation_members_unique_member_index
           )

    create index(:conversation_members, [:user_id])

    create table(:messages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :body, :text, null: false
      add :reply_to_message_id,
          references(:messages,
            type: :uuid,
            on_delete: :nilify_all,
            name: :messages_reply_to_message_id_fkey
          )

      add :json_metadata, :map, default: %{}
      add :attachments, {:array, :map}, default: []
      add :deleted_at, :utc_datetime_usec
      add :edited_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")

      add :conversation_id,
          references(:conversations,
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :user_id,
          references(:users, type: :uuid, on_delete: :nothing),
          null: false
    end

    create index(:messages, [:conversation_id, :created_at])
    create index(:messages, [:reply_to_message_id])

    create table(:message_reactions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :emoji, :text, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")

      add :message_id,
          references(:messages, type: :uuid, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :uuid, on_delete: :nothing),
          null: false
    end

    create unique_index(:message_reactions, [:message_id, :user_id, :emoji],
             name: :message_reactions_unique_user_emoji_per_message_index
           )

    create table(:mafia_games, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :text
      add :status, :text, null: false, default: "setup"
      add :phase_number, :bigint, null: false, default: 0
      add :phase_ends_at, :utc_datetime_usec
      add :day_thread_conversation_id, :uuid
      add :mafia_chat_conversation_id, :uuid
      add :ruleset, :map, null: false, default: %{}
      add :winner_faction, :text
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")

      add :host_id,
          references(:users, type: :uuid, on_delete: :nothing),
          null: false
    end

    create table(:mafia_players, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :role_name, :text
      add :alignment, :text
      add :role_pm_body, :text
      add :is_alive, :boolean, null: false, default: true
      add :eliminated_phase, :bigint
      add :eliminated_by, :text
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")

      add :mafia_game_id,
          references(:mafia_games,
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :user_id,
          references(:users, type: :uuid, on_delete: :nothing),
          null: false
    end

    create unique_index(:mafia_players, [:mafia_game_id, :user_id],
             name: :mafia_players_unique_player_index
           )

    create table(:mafia_votes, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :phase_number, :bigint, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")

      add :mafia_game_id,
          references(:mafia_games,
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :voter_player_id,
          references(:mafia_players,
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :target_player_id,
          references(:mafia_players,
            type: :uuid,
            on_delete: :delete_all
          )
    end

    create unique_index(:mafia_votes, [:mafia_game_id, :phase_number, :voter_player_id],
             name: :mafia_votes_one_vote_per_phase_index
           )

    create table(:mafia_night_actions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :phase_number, :bigint, null: false
      add :action_kind, :text, null: false
      add :mod_result, :text
      add :resolved, :boolean, null: false, default: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")

      add :mafia_game_id,
          references(:mafia_games,
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :actor_player_id,
          references(:mafia_players,
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :target_player_id,
          references(:mafia_players,
            type: :uuid,
            on_delete: :nilify_all
          )
    end

    create unique_index(
             :mafia_night_actions,
             [:mafia_game_id, :phase_number, :actor_player_id, :action_kind],
             name: :mafia_night_actions_one_action_per_kind_index
           )

    create table(:notifications, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :type, :text, null: false
      add :title, :text, null: false
      add :body, :text
      add :read_at, :utc_datetime_usec
      add :related_user_id,
          references(:users,
            type: :uuid,
            on_delete: :nothing,
            name: :notifications_related_user_id_fkey
          )

      add :metadata, :map, null: false, default: %{}

      add :user_id,
          references(:users, type: :uuid, on_delete: :delete_all),
          null: false

      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :game_id, :uuid
    end

    create index(:notifications, [:user_id, :created_at])

    Enum.each(@import_constraints, fn {table, constraint} ->
      execute(
        "ALTER TABLE #{table} ALTER CONSTRAINT #{constraint} " <>
          "DEFERRABLE INITIALLY DEFERRED"
      )
    end)
  end

  def down do
    drop table(:notifications)
    drop table(:mafia_night_actions)
    drop table(:mafia_votes)
    drop table(:mafia_players)
    drop table(:mafia_games)
    drop table(:message_reactions)
    drop table(:messages)
    drop table(:conversation_members)
    drop table(:conversations)
    drop table(:user_account_status)
    drop table(:users)
  end
end
