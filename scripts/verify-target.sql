\set ON_ERROR_STOP on

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM mafia_games WHERE status IN ('day', 'night')) THEN
    RAISE EXCEPTION 'target still contains an active Mafia game';
  END IF;

  IF EXISTS (SELECT 1 FROM oban_jobs) THEN
    RAISE EXCEPTION 'target contains background jobs before the standalone app starts';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM mafia_games AS game
    LEFT JOIN conversations AS day_thread
      ON day_thread.id = game.day_thread_conversation_id
    LEFT JOIN conversations AS mafia_chat
      ON mafia_chat.id = game.mafia_chat_conversation_id
    WHERE
      (
        game.day_thread_conversation_id IS NOT NULL
        AND (
          day_thread.id IS NULL
          OR day_thread.metadata->>'mafia_game_id' IS DISTINCT FROM game.id::text
        )
      )
      OR
      (
        game.mafia_chat_conversation_id IS NOT NULL
        AND (
          mafia_chat.id IS NULL
          OR mafia_chat.metadata->>'mafia_game_id' IS DISTINCT FROM game.id::text
        )
      )
  ) THEN
    RAISE EXCEPTION 'target has a Mafia game with an invalid conversation link';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM conversations
    WHERE NOT (
      EXISTS (
        SELECT 1
        FROM mafia_games AS game
        WHERE game.id::text = conversations.metadata->>'mafia_game_id'
      )
      OR id IN (
        SELECT day_thread_conversation_id
        FROM mafia_games
        WHERE day_thread_conversation_id IS NOT NULL
        UNION
        SELECT mafia_chat_conversation_id
        FROM mafia_games
        WHERE mafia_chat_conversation_id IS NOT NULL
      )
    )
  ) THEN
    RAISE EXCEPTION 'target contains a non-Mafia conversation';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM notifications
    WHERE NOT COALESCE((
      (
        type = 'mafia_phase'
        AND EXISTS (
          SELECT 1
          FROM mafia_games AS game
          WHERE game.id::text = notifications.metadata->>'mafia_game_id'
        )
      )
      OR
      (
        type = 'message_received'
        AND metadata->>'conversation_id' IN (SELECT id::text FROM conversations)
      )
    ), false)
  ) THEN
    RAISE EXCEPTION 'target contains a non-Mafia notification';
  END IF;
END
$$;

SELECT 'users' AS object, count(*) AS rows FROM users
UNION ALL
SELECT 'mafia_games', count(*) FROM mafia_games
UNION ALL
SELECT 'mafia_players', count(*) FROM mafia_players
UNION ALL
SELECT 'mafia_rule_revisions', count(*) FROM mafia_rule_revisions
UNION ALL
SELECT 'mafia_notebooks', count(*) FROM mafia_notebooks
UNION ALL
SELECT 'mafia_conversations', count(*) FROM conversations
UNION ALL
SELECT 'mafia_messages', count(*) FROM messages
ORDER BY object;
