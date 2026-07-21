\set ON_ERROR_STOP on

WITH kept_mafia_conversations AS (
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
  WHERE mafia_chat_conversation_id IS NOT NULL
),
kept_notifications AS (
  SELECT notification.id
  FROM notifications AS notification
  WHERE
    (
      notification.type = 'mafia_phase'
      AND EXISTS (
        SELECT 1
        FROM mafia_games AS game
        WHERE game.id::text = notification.metadata->>'mafia_game_id'
      )
    )
    OR
    (
      notification.type = 'message_received'
      AND notification.metadata->>'conversation_id' IN (
        SELECT id::text FROM kept_mafia_conversations
      )
    )
),
manifest AS (
  SELECT 'users' AS object, count(*) AS row_count,
         md5(COALESCE(string_agg(id::text, ',' ORDER BY id), '')) AS id_digest
  FROM users
  UNION ALL
  SELECT 'user_account_status', count(*),
         md5(COALESCE(string_agg(id::text, ',' ORDER BY id), ''))
  FROM user_account_status
  UNION ALL
  SELECT 'mafia_games', count(*),
         md5(COALESCE(string_agg(id::text, ',' ORDER BY id), ''))
  FROM mafia_games
  UNION ALL
  SELECT 'mafia_players', count(*),
         md5(COALESCE(string_agg(id::text, ',' ORDER BY id), ''))
  FROM mafia_players
  UNION ALL
  SELECT 'mafia_votes', count(*),
         md5(COALESCE(string_agg(id::text, ',' ORDER BY id), ''))
  FROM mafia_votes
  UNION ALL
  SELECT 'mafia_night_actions', count(*),
         md5(COALESCE(string_agg(id::text, ',' ORDER BY id), ''))
  FROM mafia_night_actions
  UNION ALL
  SELECT 'conversations', count(*),
         md5(COALESCE(string_agg(conversation.id::text, ',' ORDER BY conversation.id), ''))
  FROM conversations AS conversation
  JOIN kept_mafia_conversations AS kept ON kept.id = conversation.id
  UNION ALL
  SELECT 'conversation_members', count(*),
         md5(COALESCE(string_agg(member.id::text, ',' ORDER BY member.id), ''))
  FROM conversation_members AS member
  JOIN kept_mafia_conversations AS kept ON kept.id = member.conversation_id
  UNION ALL
  SELECT 'messages', count(*),
         md5(COALESCE(string_agg(message.id::text, ',' ORDER BY message.id), ''))
  FROM messages AS message
  JOIN kept_mafia_conversations AS kept ON kept.id = message.conversation_id
  UNION ALL
  SELECT 'message_reactions', count(*),
         md5(COALESCE(string_agg(reaction.id::text, ',' ORDER BY reaction.id), ''))
  FROM message_reactions AS reaction
  JOIN messages AS message ON message.id = reaction.message_id
  JOIN kept_mafia_conversations AS kept ON kept.id = message.conversation_id
  UNION ALL
  SELECT 'notifications', count(*),
         md5(COALESCE(string_agg(notification.id::text, ',' ORDER BY notification.id), ''))
  FROM notifications AS notification
  JOIN kept_notifications AS kept ON kept.id = notification.id
)
SELECT object || '|' || row_count::text || '|' || id_digest
FROM manifest
ORDER BY object;
