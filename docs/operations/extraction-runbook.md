# Mafia standalone-site extraction

This runbook moves Mafia once from ConquestK into its dedicated Phoenix service
and PostgreSQL database. There is no dual-write period.

## Preconditions

- The standalone Mafia release is deployed with writes disabled and `/health` is green.
- No Mafia game is in `day` or `night`; finish or delete active test games first.
- Every non-deleted copied account has a password. The small app intentionally
  has no email provider or magic-link flow, so the copy aborts if a live account
  has only magic-link credentials; set a password in ConquestK before retrying.
- The ConquestK extraction release is ready to restart after verification. It
  replaces `/mafia` with redirects, removes the integrated Mafia workers, and
  hides and rejects mutations to old Mafia-tagged chat. Deploying that release
  alone is **not** the copy-window freeze: shared account, profile, and chat
  paths can otherwise still write copied rows.
- Plan a full ConquestK outage for the copy window. Scale every ConquestK web
  and worker service to zero before the source backup/manifest is captured, and
  keep them at zero through the standalone read-only verification.
- A manual ConquestK database backup exists and its Railway
  `DATABASE_PUBLIC_URL` is available.
- The target is a dedicated Mafia PostgreSQL database with the standalone
  baseline migration applied and no application rows or Oban jobs yet.
- `psql`, `pg_dump`, and `pg_restore` are on the operator's `PATH`.

Use each database service's `DATABASE_PUBLIC_URL` with PostgreSQL 18 client
tools. Never paste either URL into a log, issue, or committed file.

Set `MAFIA_WRITES_ENABLED=false` for migration and smoke testing. Production
defaults to false when the variable is absent, so an incomplete deployment
fails closed. Change it to `true` only at production step 9 below.

## Rehearsal

1. Provision a throwaway PostgreSQL target.
2. Scale every ConquestK web and worker process to zero. Merely deploying the
   extraction release is not a write freeze.
3. Run the guarded copy command:

   ```powershell
   .\scripts\copy-database.ps1 `
     -SourceDatabaseUrl $sourceDirectUrl `
     -TargetDatabaseUrl $targetDirectUrl `
     -WritesFrozen `
     -Confirmation COPY-CONQUESTK-TO-MAFIA
   ```

4. Boot the standalone app against the copied target with writes still disabled,
   while ConquestK remains fully stopped.
5. Complete the read-only smoke test.
6. Restart ConquestK on the extraction release and confirm `/mafia` redirects
   and old Mafia-tagged conversations are hidden and reject mutations.
7. Enable standalone writes and complete the write-path smoke test below. Then
   discard the rehearsal target.

## Production cutover

1. Announce the short full-ConquestK maintenance window.
2. Confirm again that no game is active, then scale **all** ConquestK web and
   worker services to zero. Confirm no ConquestK process remains connected for
   application work. This full outage is the source freeze; deploying the
   extraction release alone is not.
3. Capture a fresh source backup after every ConquestK process is stopped.
4. Apply the standalone release migration to a fresh target, but keep the web
   service stopped so Oban cannot enqueue or execute work.
5. Run `copy-database.ps1` against the dedicated production target. The script
   imports only users/profile fields, account-status history, Mafia state,
   Mafia chat dependencies, and relevant notifications. It does not copy Risk
   tables, sessions, email tokens, or Oban jobs. It rejects duplicate source
   memberships and broken Mafia-to-conversation links, then compares row-ID
   manifests so pruning cannot silently lose Mafia data.
6. Deploy/restart the standalone app against that target, still read-only. Keep
   every ConquestK web and worker service at zero.
7. Complete the read-only smoke test while ConquestK remains fully stopped.
8. Restart ConquestK on the extraction release. Verify that `/mafia` redirects
   to the standalone site and old Mafia-tagged conversations are absent from
   Risk chat and reject direct mutation attempts.
9. Set `MAFIA_WRITES_ENABLED=true` and redeploy/restart the standalone app.
10. Complete the write-path smoke test.
11. Keep the ConquestK temporary redirects pointed at the verified standalone URL.
12. Keep the old ConquestK `mafia_*` source tables untouched until the bake
    period ends; the old runtime code has already been replaced by redirects.

The Railway service also needs `DATABASE_URL`, `SECRET_KEY_BASE`, and `PHX_HOST`.
It does not need Redis, object storage, or an email provider.

In the Railway service settings:

- connect the intended GitHub branch and enable **Wait for CI**;
- leave **Root Directory** empty and set the config-file path to `/railway.toml`;
- attach a dedicated PostgreSQL service and reference its `DATABASE_URL`;
- start with one replica, add the Mafia custom domain, and set `PHX_HOST` to it;
- generate a new `SECRET_KEY_BASE` rather than reusing ConquestK's; and
- leave `MAFIA_WRITES_ENABLED=false` until the read-only smoke test passes.

Runtime versions are pinned in `.tool-versions` and the release runs
its migrations through the checked-in `railway.toml` pre-deploy command.

The copy deliberately discards conversations merely tagged with a Mafia game ID
when that game no longer exists. They are orphaned archives, not chat for any game
being moved.

Accounts and profiles are copied once, not synchronized. The two sites share the
same password hashes and profile values only at the copy snapshot. After cutover,
password, email, and profile changes on ConquestK affect only ConquestK, while
changes on Mafia affect only Mafia; that divergence is expected.

If the script fails after restore starts, recreate and migrate the fresh target
before retrying. Restore is transactional and pruning is transactional, but the
complete restore-prune-verify workflow is intentionally not one database transaction.

## Read-only smoke test

- `/health` returns `200`.
- A copied user can sign in with their existing password and receives a new session.
- Basic profile fields render.
- Mafia lobby and copied setup/finished rooms load.
- Town/Mafia conversation membership and message history match the source.

## Write-path smoke test

- Basic profile fields can be edited.
- A host can create a game, add three players, assign roles, and start Day 1.
- A living player can post and vote; a non-host cannot remove another player.
- Hammer advances the phase, locks the day thread, and creates one Mafia Oban job.
- A shadow-muted player cannot send, edit, or react.
- Phase notifications link to the standalone room.

## Rollback boundary

Before standalone writes are enabled, the stopped ConquestK database remains the
authoritative Mafia source. If copy or read-only verification fails, discard the
target and restart the previous integrated ConquestK release against the untouched
source database. Do not restart both Mafia implementations as writable.

After standalone writes are enabled, the dedicated database is authoritative for
Mafia games, Mafia chat, Mafia notifications, and Mafia-side account/profile
changes. Keep ConquestK on the extraction release. Roll back standalone application
code by redeploying a known-good release against that same dedicated database or
fix forward. Returning Mafia to the old ConquestK database would lose new messages,
votes, phase changes, and Mafia-side profile/account changes unless a separate
reverse-import procedure is rehearsed.

Do not dual-write and do not point both applications at the dedicated database.

The standalone service must use a new `SECRET_KEY_BASE` and a Mafia-specific
session cookie name. Copied password hashes remain compatible, but no ConquestK
browser session, magic link, or reset token is valid on the new site.

## Final removal

After the standalone site has baked successfully:

1. Add a new destructive ConquestK migration that drops the four `mafia_*` tables.
2. Change the compatibility redirects for `/mafia` and `/mafia/:id` from
   temporary to permanent.
3. Regenerate both schema documents and update the launch/backup runbooks.
4. Take and restore-test the first dedicated Mafia database backup.
