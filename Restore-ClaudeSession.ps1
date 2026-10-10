# Bring back one session card in every login, e.g. after deleting it by mistake.
# Takes the card from -From, or else the newest copy in the sync backup folder, writes it
# into every login's folder with the current time, and removes its deleted_<id> tombstones
# (kept in the backup) so the next sync does not delete it again.
#   powershell -ExecutionPolicy Bypass -File .\Restore-ClaudeSession.ps1 -Id <session id or local_<id>>
# Then switch account once or restart Claude Desktop to see it.

param(
    [Parameter(Mandatory = $true)][string]$Id,
    [string]$From,
    [string[]]$SessionRoots,
    [string]$BackupRoot
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not $BackupRoot) { $BackupRoot = Join-Path $env:USERPROFILE 'claude-session-sync-backup' }
$Id = ($Id -replace '^local_', '' -replace '\.json$', '').Trim()
if ($Id -notmatch '^[0-9a-fA-F-]{36}$') { throw "Not a session id: $Id" }

if (-not $From) {
    $c = Get-ChildItem -LiteralPath $BackupRoot -Recurse -File -Filter "local_$Id*.json" -ErrorAction SilentlyContinue |
        Where-Object { (Get-RecordInfo $_.FullName).Usable } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $c) { throw "No readable backup of local_$Id.json under $BackupRoot" }
    $From = $c.FullName
}
if (-not (Get-RecordInfo $From).Usable) { throw "$From is not a readable session card" }
$bytes = Read-SharedBytes $From
Write-Host "Restoring from: $From"

$mutex = New-Object Threading.Mutex($false, 'Local\claude-session-sync')
$owned = $false
try { $owned = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { throw "A sync is still running; try again in a few seconds." }
try {
    $roots = Resolve-SessionRoots $(if ($SessionRoots) { $SessionRoots } else { Get-DefaultSessionRoots })
    $leaves = Get-Leaves $roots
    $keep = Join-Path $BackupRoot ((Get-Date -Format 'yyyyMMdd') + '\restore-removed-tombstones')
    foreach ($l in @($leaves | Where-Object { -not $_.IsLink })) {
        $tp = Join-Path $l.Path ('deleted_' + $Id)
        if (Test-Path -LiteralPath $tp) {
            New-Item -ItemType Directory -Path $keep -Force | Out-Null
            Copy-Item -LiteralPath $tp -Destination (Join-Path $keep (($l.Rel -replace '\\', '__') + '__deleted_' + $Id)) -Force
            Remove-Item -LiteralPath $tp -Force
        }
        $dst = Join-Path $l.Path "local_$Id.json"
        $tmp = Join-Path $l.Path ('.cssync-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllBytes($tmp, $bytes)   # new file: current time, so it beats the old deletion
            if (Test-Path -LiteralPath $dst) { [IO.File]::Replace($tmp, $dst, [NullString]::Value) } else { [IO.File]::Move($tmp, $dst) }
        } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
        Write-Host "  restored in $($l.Rel)"
    }
} finally { $mutex.ReleaseMutex() }
Write-Host "Done. Switch account once or restart Claude Desktop to see it."
