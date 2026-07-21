param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDatabaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$TargetDatabaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$Confirmation,

    [Parameter(Mandatory = $true)]
    [switch]$WritesFrozen
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$requiredConfirmation = "COPY-CONQUESTK-TO-MAFIA"
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$pruneScript = Join-Path $scriptDirectory "prune-target.sql"
$verifyScript = Join-Path $scriptDirectory "verify-target.sql"
$manifestScript = Join-Path $scriptDirectory "manifest.sql"
$dumpPath = Join-Path ([IO.Path]::GetTempPath()) ("mafia-copy-{0}.dump" -f [guid]::NewGuid())
$copiedTables = @(
    "users",
    "user_account_status",
    "conversations",
    "conversation_members",
    "messages",
    "message_reactions",
    "mafia_games",
    "mafia_players",
    "mafia_votes",
    "mafia_night_actions",
    "notifications"
)

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required PostgreSQL command '$Name' was not found on PATH."
    }
}

function Invoke-Checked([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "'$Command' exited with code $LASTEXITCODE."
    }
}

function Invoke-Scalar([string]$DatabaseUrl, [string]$Query, [string]$FailureMessage) {
    $result = & psql $DatabaseUrl --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 --command $Query

    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }

    return ($result | Out-String).Trim()
}

function Read-Manifest([string]$DatabaseUrl) {
    $lines = @(& psql $DatabaseUrl --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 --file $manifestScript)

    if ($LASTEXITCODE -ne 0) {
        throw "Could not build the Mafia data manifest."
    }

    return @($lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if ($Confirmation -cne $requiredConfirmation) {
    throw "Refusing to copy. Pass -Confirmation '$requiredConfirmation'."
}

if (-not $WritesFrozen) {
    throw "Refusing to copy until Mafia writes are frozen in the source application."
}

if ($SourceDatabaseUrl -eq $TargetDatabaseUrl) {
    throw "Source and target database URLs must be different."
}

foreach ($requiredScript in @($pruneScript, $verifyScript, $manifestScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Missing database-copy helper: $requiredScript"
    }
}

Require-Command "psql"
Require-Command "pg_dump"
Require-Command "pg_restore"

try {
    $activeGames = Invoke-Scalar $SourceDatabaseUrl `
        "SELECT count(*) FROM mafia_games WHERE status IN ('day', 'night');" `
        "Could not verify active Mafia games in the source database."

    if ($activeGames -ne "0") {
        throw "Refusing to copy while a Mafia game is in day/night status."
    }

    $passwordlessUsers = Invoke-Scalar $SourceDatabaseUrl `
        "SELECT count(*) FROM users WHERE deleted_at IS NULL AND hashed_password IS NULL;" `
        "Could not verify copied users have password credentials."

    if ($passwordlessUsers -ne "0") {
        throw "Refusing to copy: $passwordlessUsers non-deleted user(s) rely on magic-link login. Set passwords in ConquestK before retrying."
    }

    $duplicateMembershipQuery = @"
SELECT count(*)
FROM (
  SELECT conversation_id, user_id
  FROM conversation_members
  GROUP BY conversation_id, user_id
  HAVING count(*) > 1
) AS duplicates;
"@
    $duplicateMemberships = Invoke-Scalar $SourceDatabaseUrl $duplicateMembershipQuery `
        "Could not check the source for duplicate conversation memberships."

    if ($duplicateMemberships -ne "0") {
        throw "Refusing to copy: the source has duplicate conversation memberships. Clean them up before retrying."
    }

    $invalidConversationLinksQuery = @"
SELECT count(*)
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
  );
"@
    $invalidConversationLinks = Invoke-Scalar $SourceDatabaseUrl $invalidConversationLinksQuery `
        "Could not validate the source Mafia conversation links."

    if ($invalidConversationLinks -ne "0") {
        throw "Refusing to copy: a source Mafia game has a missing or mismatched conversation."
    }

    $targetRowsQuery = @"
SELECT
  (SELECT count(*) FROM users) +
  (SELECT count(*) FROM user_account_status) +
  (SELECT count(*) FROM conversations) +
  (SELECT count(*) FROM conversation_members) +
  (SELECT count(*) FROM messages) +
  (SELECT count(*) FROM message_reactions) +
  (SELECT count(*) FROM mafia_games) +
  (SELECT count(*) FROM mafia_players) +
  (SELECT count(*) FROM mafia_votes) +
  (SELECT count(*) FROM mafia_night_actions) +
  (SELECT count(*) FROM notifications) +
  (SELECT count(*) FROM oban_jobs);
"@
    $targetRows = Invoke-Scalar $TargetDatabaseUrl $targetRowsQuery `
        "Could not verify the migrated Mafia target database."

    if ($targetRows -ne "0") {
        throw "Refusing to import into a non-empty target database. Provision and migrate a fresh target."
    }

    $sourceManifest = @(Read-Manifest $SourceDatabaseUrl)

    Write-Host "Dumping only accounts, Mafia state, Mafia chat dependencies, and notifications..."
    $dumpArguments = @(
        "--format=custom",
        "--data-only",
        "--no-owner",
        "--no-acl",
        "--file=$dumpPath"
    )

    foreach ($table in $copiedTables) {
        $dumpArguments += "--table=public.$table"
    }

    $dumpArguments += $SourceDatabaseUrl
    Invoke-Checked "pg_dump" $dumpArguments

    Write-Host "Importing into the empty, migrated Mafia target database..."
    Invoke-Checked "pg_restore" @(
        "--data-only",
        "--no-owner",
        "--no-acl",
        "--exit-on-error",
        "--single-transaction",
        "--dbname=$TargetDatabaseUrl",
        $dumpPath
    )

    Write-Host "Removing unrelated conversations and notifications..."
    Invoke-Checked "psql" @(
        $TargetDatabaseUrl,
        "--no-psqlrc",
        "--set", "ON_ERROR_STOP=1",
        "--file", $pruneScript
    )

    Write-Host "Verifying the dedicated Mafia database..."
    Invoke-Checked "psql" @(
        $TargetDatabaseUrl,
        "--no-psqlrc",
        "--set", "ON_ERROR_STOP=1",
        "--file", $verifyScript
    )

    $targetManifest = @(Read-Manifest $TargetDatabaseUrl)
    $manifestDifference = Compare-Object -ReferenceObject $sourceManifest -DifferenceObject $targetManifest

    if ($manifestDifference) {
        Write-Host "Expected source manifest:"
        $sourceManifest | ForEach-Object { Write-Host "  $_" }
        Write-Host "Actual target manifest:"
        $targetManifest | ForEach-Object { Write-Host "  $_" }
        throw "The target Mafia manifest does not match the frozen source. Recreate the target before retrying."
    }

    Write-Host "Database copy complete and all Mafia row IDs match the frozen source manifest."
    Write-Host "Keep the source frozen until the new site passes its read-only smoke test."
}
finally {
    if (Test-Path -LiteralPath $dumpPath -PathType Leaf) {
        Remove-Item -LiteralPath $dumpPath -Force
    }
}
