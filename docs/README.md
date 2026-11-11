# Night Jury documentation

> **Maintenance status — November 11, 2026:** This is an inactive personal project, shared for reference and experimentation. No ongoing feature work, releases, or support response times are planned. Issues and pull requests may go unanswered.

For current setup, runtime configuration, gameplay basics, tests, troubleshooting, and contribution expectations, start with the [README](../README.md).

| Document | When it is useful |
|---|---|
| [Database schema](operations/database-schema.md) | Understanding the extracted application's tables and relationships |
| [Extraction runbook](operations/extraction-runbook.md) | Reviewing the original guarded copy/cutover process; a fresh install does not need it |
| [Mafia side-game plan](planning/mafia-side-game.md) | Historical design context, rather than a list of completed or scheduled features |

The executable reference is [mix.exs](../mix.exs), [configuration](../config), [routes](../lib/mafia_web/router.ex), and [rules](../lib/mafia/game_rules.ex). This source snapshot does not grant access to another installation's database, accounts, or infrastructure.
