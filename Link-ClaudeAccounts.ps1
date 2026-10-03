# Make every Claude Desktop login on this PC share ONE Code-tab session list:
# any official account, and third-party / gateway mode (the "Claude-3p" profile
# that tools like CC Switch put the desktop app into).
#
# Claude Desktop keeps the session list per login at
#   <userData>\claude-code-sessions\<accountUuid>\<orgUuid>\local_*.json
# while the conversations themselves (~\.claude\projects\*.jsonl) are shared.
# This script keeps one real folder as the master and turns every other
# account/org folder into an NTFS junction (no admin rights needed) pointing at it.
#
# Usage (Windows PowerShell 5.1; PowerShell 7 is untested). Quit Claude Desktop first (tray icon -> Quit).
#   powershell -ExecutionPolicy Bypass -File .\Link-ClaudeAccounts.ps1          # dry run, changes nothing
#   powershell -ExecutionPolicy Bypass -File .\Link-ClaudeAccounts.ps1 -Apply   # do it

param(
    [switch]$Apply,
    [string]$Master,          # optional: path of the real folder to use as the shared list
    [string[]]$SessionRoots,  # optional: override root discovery (used by the tests)
    [string]$BackupDir        # optional: where replaced folders are kept (must be on the same drive)
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$custom = $PSBoundParameters.ContainsKey('SessionRoots')
$roots = Resolve-SessionRoots $(if ($custom) { $SessionRoots } else { Get-DefaultSessionRoots })
if ($roots.Count -eq 0) { throw "No Claude Desktop session folders found. Open the Code tab once first." }
$roots | ForEach-Object { Write-Host "Session root: $_" }

if ($Apply -and (Test-DesktopRunning $roots (-not $custom))) {
    throw "Claude Desktop is running. Quit it completely (tray icon -> Quit), then run this again."
}

$leaves = Get-Leaves $roots
if ($leaves.Count -eq 0) { throw "No account folders found. Open the Code tab once first." }

# --- the master, in order: -Master; what existing links point at; the folder marked as
#     master by an earlier run; else the official profile first (first root), biggest folder
$real = @($leaves | Where-Object { -not $_.IsLink })
$targets = @($leaves | Where-Object { $_.IsLink } | ForEach-Object { $_.Target } | Sort-Object -Unique)
$marked = @($real | Where-Object { $_.Marked })
if ($Master) {
    $full = Get-AbsolutePath $Master
    $m = $real | Where-Object { $_.Path -ieq $full }
    if (-not $m) { throw "Master '$Master' is not a real account folder under the session roots." }
} elseif ($targets.Count -gt 1) {
    throw ("Existing links point at different folders; pass -Master to choose one:`n  " + ($targets -join "`n  "))
} elseif ($targets.Count -eq 1) {
    $m = $real | Where-Object { $_.Path -ieq $targets[0] }
    if (-not $m) { throw "Existing links point at $($targets[0]), which is gone (the shared list is missing). $script:MissingListHelp" }
} elseif ($marked.Count -ge 1) {
    $m = $marked | Sort-Object RootIndex, Path | Select-Object -First 1
} else {
    $m = $real | Sort-Object RootIndex, @{ Expression = 'Count'; Descending = $true }, Path | Select-Object -First 1
}
$m = @($m)[0]
Write-Host "Master (shared) list: $($m.Path)  [$($m.Count) sessions]"

$BackupDir = Get-AbsolutePath $(if ($BackupDir) { $BackupDir } else { Join-Path $env:USERPROFILE ("claude-session-link-backup\" + (Get-Date -Format 'yyyyMMdd-HHmmss')) })
$masterBefore = Join-Path $BackupDir 'master-before'
$todo = 0; $errors = 0; $linked = 0

foreach ($l in $leaves) {
    if ($l.Path -ieq $m.Path) { continue }
    if ($l.IsLink) {
        if ($l.Target -ieq $m.Path) { Write-Host "OK      $($l.Rel) already linked"; $linked++ }
        else { Write-Warning "SKIP    $($l.Rel) is a link to something else: $($l.Target)"; $errors++ }
        continue
    }
    $todo++

    # --- plan the merge
    $copy = @(); $update = @(); $skipDeleted = 0; $unusable = 0; $deletedHere = 0; $others = @(); $tasks = $false
    foreach ($f in @(Get-ChildItem -LiteralPath $l.Path -Force)) {
        if ($f.Name -like 'local_*.json' -and -not $f.PSIsContainer) {
            $id = $f.BaseName.Substring(6)
            $dst = Join-Path $m.Path $f.Name
            if (-not (Get-RecordInfo $f.FullName).Usable) { $unusable++; continue }                 # never spread a file the app cannot read
            if (Test-Path -LiteralPath (Join-Path $m.Path ('deleted_' + $id))) { $skipDeleted++; continue }   # deleted in the master stays deleted
            if (-not (Test-Path -LiteralPath $dst)) { $copy += $f; continue }
            if (Test-IncomingWins $f.FullName $dst) { $update += $f }
        } elseif ($f.Name -like 'deleted_*') {
            if (Test-Path -LiteralPath (Join-Path $m.Path ('local_' + $f.Name.Substring(8) + '.json'))) { $deletedHere++ }
        } elseif ($f.Name -eq $script:MasterMarker -or $f.Name -like '.cslink-probe-*') {
            # ours
        } elseif (-not (Test-SameContent $f.FullName (Join-Path $m.Path $f.Name))) {
            $others += $f.Name   # differs from the master's copy (or the master has none)
            if ($f.Name -eq 'scheduled-tasks.json' -and ([IO.File]::ReadAllText($f.FullName) -match '"scheduledTasks"\s*:\s*\[\s*\{')) { $tasks = $true }
        }
    }

    Write-Host ("LINK    {0}  -> master  (add {1}, update {2}, skip {3} deleted in master)" -f $l.Rel, $copy.Count, $update.Count, $skipDeleted)
    if ($unusable -gt 0) { Write-Warning "        $unusable record(s) here are unreadable by the app (BOM/empty/invalid JSON); not merged, kept in the backup" }
    if ($deletedHere -gt 0) { Write-Warning "        $deletedHere session(s) deleted in this login still exist in the master and will show again" }
    if ($tasks) { Write-Warning "        this login has its own scheduled tasks; they are kept in the backup, re-create them after linking" }
    if ($others.Count -gt 0) { Write-Host ("        differs from the master, not merged, kept in the backup: " + ($others -join ', ')) }
    if (-not $Apply) { continue }

    # --- safety checks before touching anything
    if ([IO.Path]::GetPathRoot($BackupDir) -ine [IO.Path]::GetPathRoot($l.Path)) {
        Write-Warning "FAILED  $($l.Rel): backup folder $BackupDir is on another drive; pass -BackupDir on $([IO.Path]::GetPathRoot($l.Path))"
        $errors++; continue
    }
    $probe = Join-Path $m.Path ('.cslink-probe-' + [guid]::NewGuid().ToString('N'))
    $same = $null
    try {
        [IO.File]::WriteAllText($probe, '')
        $same = Test-Path -LiteralPath (Join-Path $l.Path ([IO.Path]::GetFileName($probe)))
    } catch {
        Write-Warning "FAILED  $($l.Rel): could not verify it is a different folder from the master ($($_.Exception.Message))"
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
    if ($same -ne $false) {
        if ($same) { Write-Warning "FAILED  $($l.Rel) is the same physical folder as the master (linked elsewhere); not touched" }
        $errors++; continue
    }

    # --- merge, then swap the folder for a link
    $dest = Join-Path $BackupDir ($l.Rel -replace '\\', '__')
    try {
        New-Item -ItemType Directory -Path $masterBefore -Force | Out-Null
        foreach ($f in $copy) { Copy-Item -LiteralPath $f.FullName -Destination $m.Path }
        foreach ($f in $update) {
            $keep = Join-Path $masterBefore $f.Name
            if (-not (Test-Path -LiteralPath $keep)) { Copy-Item -LiteralPath (Join-Path $m.Path $f.Name) -Destination $keep }   # keep the master's original, once
            Copy-Item -LiteralPath $f.FullName -Destination $m.Path -Force
        }
        Move-Item -LiteralPath $l.Path -Destination $dest
    } catch {
        Write-Warning "FAILED  $($l.Rel): $($_.Exception.Message). Not linked; records already merged stay in the master."
        $errors++; continue
    }
    try {
        # PowerShell 5.1 expands wildcards in -Target, so escape [ ]; then read the link back
        $tgt = if ($PSVersionTable.PSVersion.Major -lt 6) { [WildcardPattern]::Escape($m.Path) } else { $m.Path }
        New-Item -ItemType Junction -Path $l.Path -Target $tgt | Out-Null
        $got = ([string]((Get-Item -LiteralPath $l.Path -Force).Target -join '')).TrimEnd('\')
        if ($got -ine $m.Path) { [IO.Directory]::Delete($l.Path, $false); throw "the new link points at '$got'" }
        Write-Host "        done. old folder kept at $dest"
        $linked++
    } catch {
        Write-Warning "FAILED  $($l.Rel): could not create the link ($($_.Exception.Message)); putting the folder back."
        try {
            if (-not (Test-Path -LiteralPath $l.Path)) { Move-Item -LiteralPath $dest -Destination $l.Path }
        } catch {
            Write-Warning "        could not put it back either ($($_.Exception.Message)). The folder is safe at: $dest  - move it back to $($l.Path) by hand."
        }
        $errors++
    }
}

# mark the master once at least one login really uses it, so it stays the master later
if ($Apply -and $linked -gt 0 -and -not $m.Marked) {
    try { [IO.File]::WriteAllText((Join-Path $m.Path $script:MasterMarker), 'This folder is the shared Claude session list (claude-session-link).') }
    catch { Write-Warning "could not write the master marker: $($_.Exception.Message)" }
}

if (-not $Apply -and $todo -gt 0) { Write-Host "`nDry run only. Quit Claude Desktop, then re-run with -Apply." }
if ($todo -eq 0 -and $errors -eq 0) { Write-Host "`nNothing to do: every login already shares the master list." }
if ($errors -gt 0) { exit 1 }
