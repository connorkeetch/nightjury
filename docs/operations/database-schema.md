# Mafia standalone database

The standalone service owns a deliberately small PostgreSQL schema. Its source
of truth is
[`priv/repo/migrations/20260720000100_create_mafia_schema.exs`](../../priv/repo/migrations/20260720000100_create_mafia_schema.exs).

## Owned data

| Area | Tables |
| --- | --- |
| Accounts and profiles | `users`, `user_account_status` |
| Chat | `conversations`, `conversation_members`, `messages`, `message_reactions` |
| Mafia | `mafia_games`, `mafia_players`, `mafia_votes`, `mafia_night_actions` |
| Inbox | `notifications` |
| Jobs | Oban's `oban_jobs`, `oban_peers`, and supporting objects |

The `users` table retains the source columns needed for a lossless one-time
`pg_dump`/`pg_restore`, even though the Mafia app exposes only username, email,
password hash, avatar, tagline, and bio. `conversations.game_id` and
`notifications.game_id` are compatibility columns without Risk foreign keys.

The app does not own Risk games, maps, rankings, clans, achievements, social
graphs, uploads, browser sessions, email/reset tokens, or Risk background jobs.
Those tables and rows are never copied.

All imported foreign keys are `DEFERRABLE INITIALLY DEFERRED`, allowing the
guarded copy script to restore the selected tables atomically. After import,
unrelated conversations and notifications are removed before verification. A
source/target manifest compares both counts and deterministic ID digests for
every retained table so pruning cannot silently lose Mafia data.
