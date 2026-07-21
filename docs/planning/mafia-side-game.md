# Mafia — Standalone Site

**Status:** standalone repository · **Owner:** Connor · **Bias:** YAGNI / reuse-first.

> This document records the original product decisions. Mafia no longer lives
> inside the Risk Phoenix runtime: it is a dedicated Phoenix app, Railway
> service, and PostgreSQL database. Operational cutover steps live in
> [the extraction runbook](../operations/extraction-runbook.md), and the
> owned tables are listed in
> [the standalone schema reference](../operations/database-schema.md).

A play-by-post Mafia (Werewolf) site that remains part of the ConquestK community
without sharing the Risk game runtime or database.
The group currently plays this manually in a forum on another site (d12); we bring it
in-house with **a small automation layer over a human moderator** — not a Town-of-Salem
state machine.

Grounding research finding: the canonical forum tools (MafiaScum votecounter / Modbot)
automate **only vote-counting + a deadline clock and nothing else.** That is the entire
proven product. We build "human mod + tooling," and automate the *mechanical* toil.

## Decisions (locked)

| Decision | Choice |
|---|---|
| Deadline behavior | **Auto-resolve** the lynch at the day deadline (plurality leader, no mod gate). Mod can override. Avoids "awaiting mod" limbo for an async, cross-timezone group. |
| Moderator | **Neutral overseer.** Host runs the game, sees all roles, is *not* in `mafia_players`. Added as `:admin` to every conversation so mute + system posts work. |
| Ranking / ELO | **None.** Social, asymmetric, fun-only. No stats wiring. |
| Placement | **Dedicated site.** Old ConquestK `/mafia` links redirect to it. |
| Lobby | **Per-game option** at creation: `open` (public list, anyone joins) or `invite` (mod adds players). Mod can kick in both. |

### Defaults (mod can change per game)
- Phase length: 24h day / 24h night.
- Vote rule: majority + hammer (still auto-resolves at deadline).
- Reveal on death: full role flip (per-game flag).
- Dead players: read-only on day thread + a separate read-write "graveyard" chat.

## Architecture

**Reuse the chat system wholesale. Skip GameServer/GameEngine/TurnTimerWorker (all
Risk-shaped). Lean Postgres + one Oban worker + an hourly reconciler.**

No GenServer-per-room: that pattern serializes many actions/second (Risk attacks).
Mafia is async play-by-post over 24h phases — write rate is a few votes an hour. State
lives in Postgres, read on each LiveView mount. A GenServer here is pure overhead.

### Extraction provenance (historical)

The first implementation reused ConquestK's account, profile, chat, Ash resource,
Oban, and LiveView patterns. Those pieces were copied once and now evolve in this
repository; there is no runtime or source dependency on ConquestK.

## MVP scope

**Automations (the user's intuition):**
1. **Structured vote + live Vote Count.** Vote/Unvote buttons (LiveView events, not
   bolded-text parsing). `mafia_votes` unique per (phase, voter). Live tally HUD via
   PubSub `mafia:<id>`. Hammer = `floor(living/2)+1`.
2. **Auto-mute the dead.** On elimination → `shadow_muted` on the day-thread membership.
3. **Phase clock + auto lock/unlock.** `MafiaPhaseWorker` (Oban, `schedule_in`,
   24h default): lock day thread, open night channels, post system message, countdown.
4. **Gated night conversations.** Tagged group conversations with per-channel
   `open_window` (`night_only | always`) flipped on phase change; per-player cap.

**Reliability + integrity (non-optional, from adversarial review):**
5. **Hourly cron reconciler** — scans `mafia_games WHERE phase_ends_at < now() AND status
   IN (day,night)` and force-advances. A one-shot 24h Oban job on a daily-redeploying
   Railway instance has no re-arm; this is the backstop. Ships in v1.
6. **`is_read_only` flag** on the conversation (Ash) + enforced in send policy — clean
   thread-lock instead of O(N) shadow-mute churn. (Legacy Ecto schema already has it.)
7. **`MafiaModLive`** host-only dashboard — roster, night-action queue, role assignments,
   confirm/resolve/kick buttons. For archetype-#1 Mafia this *is* the product.
8. **Integrity guards** — Ash validations: `voter.is_alive` + `phase == :day and now <
   deadline` on votes (same for night actions); lock message edits in Mafia conversations;
   confirm reaction policy also respects shadow_mute (dead must not signal via emoji).

**Implementation gotchas (verified):**
- `:shadow_mute` action needs an **admin-of-conversation** policy (not self-only
  `update_preferences`); host must be `:admin` member of moderated conversations.
- **System messages** need a sender that bypasses the send policy — route through the
  existing `is_admin` bypass; never mute the host.

## Data model (5 tables, no generic engine)

```
mafia_games      id, host_id, title, status(setup|day|night|finished),
                 phase_number, phase_ends_at, day_thread_conversation_id,
                 mafia_chat_conversation_id, ruleset :map(jsonb)

mafia_players    mafia_game_id, user_id, role_name :string,   # free text in v1
                 alignment(:town|:mafia), role_pm_body :text,
                 is_alive, eliminated_phase, eliminated_by(:lynch|:night|:modkill)
                 unique(mafia_game_id, user_id)

mafia_votes      mafia_game_id, phase_number, voter_player_id,
                 target_player_id (null = No Lynch)
                 unique(mafia_game_id, phase_number, voter_player_id)

mafia_night_actions  mafia_game_id, phase_number, actor_player_id,
                 action_kind :string, target_player_id, mod_result :text,
                 resolved bool   # COLLECTION only — the mod resolves by hand
                 unique(mafia_game_id, phase_number, actor_player_id, action_kind)
```

No role-catalog, phases, or factions table. `:third_party` is intentionally **left out**
of the alignment enum until v2 (it would break the vanilla parity auto-check).

## Day / night loop

`MafiaPhaseWorker` (Oban) + hourly cron reconciler.

```
DAY N   phase_ends_at = now + ruleset.day_length; worker scheduled for it
        players discuss in day thread, cast Vote/Unvote; live VC via mafia:<id>
        hammer reached OR deadline → AUTO-RESOLVE the lynch (plurality leader)
        → flip is_alive, shadow_mute the dead, post flip, recompute living,
          vanilla parity check → if met, surface "End game?" to mod

NIGHT N AUTO: lock day thread (is_read_only), open mafia + night_only channels,
          post "Night N — submit actions"
        players submit via night-action FORM → mafia_night_actions (collect only)
        MOD RESOLVES by hand, records deaths + mod_result, clicks "Open Day N+1"
        → AUTO: shadow_mute night-killed, close night channels, unlock day,
          post dawn results, phase_number++
```

Auto: clock, lock/unlock, channel gating, hammer detection, live VC, mute-the-dead,
system posts, vanilla parity. Mod does: the night resolution, flavor text, ending the
game, kicks.

## Customizable rules — JSONB, no interpreter

`mafia_games.ruleset` read as plain map lookups (like `king_of_the_hill_config`):

```elixir
%{
  "lobby_type" => "open",            # "open" | "invite"
  "day_length_seconds" => 86_400, "night_length_seconds" => 86_400,
  "vote_type" => "majority",         # "majority"+hammer | "plurality"
  "allow_no_lynch" => true,
  "reveal_on_death" => "full",       # "full" | "alignment" | "none"
  "channels" => [%{"name" => "mafia", "open_window" => "always"}, ...],
  "night_conversation_cap" => 2
}
```

Role list = the `role_name` strings the mod types per player. We don't model what a role
*does* in v1. Ship 2–3 fixed known-balanced presets (Mountainous + one light power-role).
No generative balancer.

## Phasing — NOT in v1

| Skip now | Add when |
|---|---|
| Night-action **resolver** (NAR priority, roleblock/protect/redirect math) | A specific repeated setup justifies encoding its roles. Collect via form, mod resolves. |
| Role-power modeling / role catalog | Arrives with the resolver. |
| Third-party / neutral / cult / lovers | Players request them. |
| Mafia AI | Probably never for a social side-game. |
| Generative setup balancer | Likely never — keep setup design human. |
| GameServer / GenServer hot state | Only if profiling ever shows Postgres-read-on-mount too slow (it won't at this scale). |

**v2 (if v1 lands):** a constrained resolver for a whitelisted role set
(Cop/Doctor/Roleblocker/Vigilante), always with a mod override.

## File map

- Game orchestration: `lib/mafia/games.ex` and `lib/mafia/games/resources/`.
- Chat and profiles: `lib/mafia/chat.ex`, `lib/mafia/chat/`, and `lib/mafia/accounts/`.
- Scheduled phase work: `lib/mafia/workers/`.
- LiveView UI: `lib/mafia_web/live/`.
- Database ownership: `priv/repo/migrations/`.
- Railway data cutover: `scripts/copy-database.ps1`.
