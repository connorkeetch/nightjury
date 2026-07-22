# Nightjury

Nightjury is a standalone Phoenix LiveView Mafia game, extracted from
[ConquestK](https://github.com/connorkeetch/conquestk). It owns its PostgreSQL
database, authentication, profiles, chat, notifications, and background jobs.

## Development

Requires Elixir 1.20, OTP 29, and PostgreSQL 17. Versions are pinned in
`.tool-versions`.

```bash
mix setup
mix phx.server
```

The app runs at <http://localhost:4001>. On Windows, load the Visual Studio C++
environment before compiling `bcrypt_elixir`, or use the included wrapper:

```powershell
.\mix-vs.bat setup
.\mix-vs.bat phx.server
```

## Deployment

Railway configuration lives in `railway.toml`. Required variables are
`DATABASE_URL`, `SECRET_KEY_BASE`, and `PHX_HOST`; keep
`MAFIA_WRITES_ENABLED=false` until the one-time copy has been verified.

See the [extraction runbook](docs/operations/extraction-runbook.md) for the
guarded database copy and production cutover.
