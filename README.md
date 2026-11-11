# Night Jury

A standalone, play-by-post **Mafia / social deduction game** built with Elixir and Phoenix LiveView. Players discuss and vote in a shared room while a human moderator manages hidden roles, day/night phases, and the rules.

> **Maintenance status — November 11, 2026:** This is an inactive personal project, shared for reference and experimentation. No ongoing feature work, releases, or support response times are planned. Issues and pull requests may go unanswered.

## What is included?

- Public lobby browsing and account registration; signed-in users can host games.
- Configurable ballots, factions, phase timers, player capabilities, and house rules.
- Game rooms, moderator settings, player notes, profiles, forums, private messages, notifications, and background jobs.
- Its own PostgreSQL database and authentication. A running ConquestK server is not required.

Night Jury was extracted from [ConquestK](https://github.com/connorkeetch/conquestk). Names such as `Mafia`, `:mafia`, and `MafiaWeb` remain internal identifiers. A role name is data, not an executable role script; moderators still adjudicate their games.

## Local setup

Use the versions pinned in [.tool-versions](.tool-versions): **Elixir 1.20.1 / Erlang OTP 29.0.1**. PostgreSQL 17 is the database version used by [CI](.github/workflows/ci.yml). Native build tools are needed for dependencies such as `bcrypt_elixir`.

```bash
git clone https://github.com/connorkeetch/nightjury.git
cd nightjury
mix setup
mix phx.server
```

Open <http://localhost:4001>. `mix setup` downloads dependencies and asset tools, creates and migrates the development database, and builds assets. The seed file is intentionally empty: register your own account at `/users/register`; no demo login is supplied.

The defaults below must match a PostgreSQL role that can create the development and test databases. Set these variables in your shell if your local installation differs:

| Variable | Development default |
|---|---|
| `POSTGRES_HOST` | `localhost` |
| `POSTGRES_PORT` | `5432` |
| `POSTGRES_USER` | `postgres` |
| `POSTGRES_PASSWORD` | `postgres` — local development only |
| `POSTGRES_DATABASE` | `mafia_dev` |
| `PORT` | `4001` |

For example, in Bash use `export POSTGRES_PASSWORD='your-local-password'`; in PowerShell use `$env:POSTGRES_PASSWORD = 'your-local-password'`. Configuration reads shell environment variables directly; copying values into an arbitrary `.env` file does not load them automatically.

On Windows, load the Visual Studio C++ build environment before compiling native dependencies, or use the included wrapper:

```powershell
.\mix-vs.bat setup
.\mix-vs.bat phx.server
```

The asset pipeline is managed through Mix tasks. There is no separate Node server or Redis requirement in this application.

## Try a game

1. Browse `/` or `/mafia`, then register or sign in to host.
2. Create a game and review its settings and rules. The host is a moderator and need not join as a player.
3. Have players register their own accounts and join the lobby. The default minimum is three players; settings can change it.
4. Use the game's rules page at `/mafia/<id>/rules`, moderator settings, voting, and phase controls. This is a human-run game, rather than a fully automated moderator.

The [rules module](lib/mafia/game_rules.ex) defines supported configuration; [routes](lib/mafia_web/router.ex) show available pages.

## Development checks

Run from the repository root with a local PostgreSQL server:

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix ash.codegen --check
mix assets.build
mix test
```

Tests use an isolated, checkout-specific database name by default. **An explicit `POSTGRES_DATABASE` overrides that name in tests too.** Unset a development override before testing, or set it to a dedicated disposable test database. `mix ecto.reset` drops its target database; it is not a troubleshooting step for a database you need to keep.

These commands match the checked-in workflow. They were not rerun against a fresh full installation for this documentation update.

## Deployment and configuration

[railway.toml](railway.toml) defines release migration/start commands and the `/health` endpoint. Build your own release and use your own database, domain, and secrets.

| Production variable | Purpose |
|---|---|
| `DATABASE_URL` | PostgreSQL URL for this installation |
| `SECRET_KEY_BASE` | Stable secret generated with `mix phx.gen.secret` |
| `PHX_HOST` | Your public hostname, without a URL scheme |
| `PORT` | HTTP port; defaults to `4000` |
| `POOL_SIZE` | Database connection pool; defaults to `10` |
| `MAFIA_WRITES_ENABLED` | Defaults to `false` in production; set `true` only when your own database is ready to accept writes |

See [runtime configuration](config/runtime.exs) for optional clustering and Railway-origin handling. A read-only production instance usually means the write gate is still disabled. Local development enables writes by default.

The [extraction runbook](docs/operations/extraction-runbook.md) documents the original guarded database copy and cutover. **It is historical migration guidance, not a prerequisite for a fresh installation.** Do not copy another installation's user data, reuse its credentials, or assume access to its deployment.

## Common questions and troubleshooting

| Question | Answer |
|---|---|
| Is this actively developed? | No. The public source is preserved for people who want to study or run it; no roadmap or support schedule is promised. |
| Does it share accounts or browser sessions with ConquestK? | No shared live session is required. Fresh installations start with their own database and registered users. The extraction runbook is only for an intentional migration. |
| Can I play without a human moderator? | The product is designed around a human moderator. Role labels and configurable rules do not automate every role's actions. |
| Database connection or permission errors? | Check PostgreSQL is running, the `POSTGRES_*` variables match, and the role can create the target databases. Development uses these variables, while production uses `DATABASE_URL`. |
| Native dependency compilation fails on Windows? | Install the appropriate C++ build tools and use `mix-vs.bat`, or run in a suitable Linux/WSL development environment. |
| UI assets are missing? | Run `mix assets.setup` and `mix assets.build`; dependency and asset downloads require network access. |
| Is every idea in the planning document implemented? | No. Planning documents record design intent; use the routes, code, and tests to establish current behavior. |
| Where can I ask a question or report a bug? | Search [issues](https://github.com/connorkeetch/nightjury/issues) first. Include OS, toolchain versions, reproduction steps, and redacted logs. Replies and PR review are not guaranteed. Never post passwords, session tokens, or private player messages. |
| What license applies? | Project source code is available under the [MIT License](LICENSE). Third-party dependencies, assets, and services retain their own terms. |

## Code and documentation map

| Path | Contents |
|---|---|
| [lib/mafia](lib/mafia) | Accounts, games, rules, persistence, and jobs |
| [lib/mafia_web](lib/mafia_web) | LiveView pages, controllers, authentication, and routes |
| [config](config) | Development, test, and production configuration |
| [priv/repo](priv/repo) | Database migrations and seeds |
| [test](test) | Automated tests |
| [docs/README.md](docs/README.md) | Documentation index and history |

Pull requests should target `main`, stay focused, and include the relevant checks above. Public availability is not a promise of ongoing maintenance.
