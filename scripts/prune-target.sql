\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM mafia_games WHERE status IN ('day', 'night')) THEN
    RAISE EXCEPTION 'refusing to prune a database with an active Mafia game';
  END IF;
END
$$;

CREATE TEMPORARY TABLE kept_mafia_conversations ON COMMIT DROP AS
SELECT conversation.id
FROM conversations AS conversation
WHERE EXISTS (
  SELECT 1
  FROM mafia_games AS game
  WHERE game.id::text = conversation.metadata->>'mafia_game_id'
)
UNION
SELECT day_thread_conversation_id
FROM mafia_games
WHERE day_thread_conversation_id IS NOT NULL
UNION
SELECT mafia_chat_conversation_id
FROM mafia_games
WHERE mafia_chat_conversation_id IS NOT NULL;

-- Conversation deletion cascades through members, messages, reactions, and
-- their reactions via the standalone schema's foreign keys.
DELETE FROM conversations
WHERE id NOT IN (SELECT id FROM kept_mafia_conversations);

-- Preserve Mafia phase notifications and mentions that still point at a kept
-- Mafia conversation. All Risk-game and now-unreachable chat notifications go.
DELETE FROM notifications
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
    AND metadata->>'conversation_id' IN (
      SELECT id::text FROM kept_mafia_conversations
    )
  )
), false);

COMMIT;
