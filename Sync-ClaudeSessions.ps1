# Keep the Claude Desktop Code-tab session list identical for every login on this PC
# (official accounts and the third-party "Claude-3p" profile).
#
# Claude Desktop stores one small "card" per session at
#   <userData>\claude-code-sessions\<accountUuid>\<orgUuid>\local_<id>.json
# and refuses to save into a folder that is a link, so every login keeps its own
# real folder. The conversations themselves (~\.claude\projects\*.jsonl) are a
# single shared copy and are never read or written by this script.
#
# Every run merges the cards of all those folders:
#   - a card missing from a folder is copied in
#   - when copies differ, the best one goes everywhere (see Select-BestCopy in common.ps1:
#     readable > not out of date > not damaged > newer lastActivityAt > newer file time)
#   - a session deleted in one login (deleted_<id> tombstone) is removed from the others,
#     unless its card was changed after the deletion
#   - a card that could not be read, or a folder that could not be listed, is not
#     written to in that run (an unreadable newest copy must never be overwritten)
#   - every card it replaces or removes is copied to the backup folder first, and all
#     cards are snapshotted once a day (kept 14 days)
#
# Hooks (see Install-SyncHook.ps1): Stop, StopFailure and SessionEnd run it with -Followup,
# which syncs now and once more 3 s and 10 s later (Claude Desktop writes a turn's last
# card update only after the Stop hook returns). SessionStart runs it plainly.
#   powershell -ExecutionPolicy Bypass -File .\Sync-ClaudeSessions.ps1        # by hand

param(
    [string[]]$SessionRoots,   # optional: override root discovery (used by the tests)
    [string]$BackupRoot,       # optional: default %USERPROFILE%\claude-session-sync-backup
    [switch]$Followup,         # sync now, then start a short-lived helper that syncs again at +3 s and +10 s
    [switch]$Delayed,          # (internal) the helper started by -Followup
    [string]$RootsList,        # (internal) -SessionRoots joined with '|' (-File cannot repeat a parameter)
    [switch]$Verbose2          # print every action
)

$ErrorActionPreference = 'Stop'
$script:log = @()
function Note($msg) { $script:log += $msg; if ($Verbose2) { Write-Host $msg } }
function Detail($msg) { if ($Verbose2) { Write-Host $msg } }   # routine per-card lines: screen only, kept out of the log
if (-not $BackupRoot) { $BackupRoot = Join-Path $env:USERPROFILE 'claude-session-sync-backup' }

function Invoke-Sync {
    $roots = Resolve-SessionRoots $(if ($SessionRoots) { $SessionRoots } else { Get-DefaultSessionRoots })
    $leaves = Get-Leaves $roots   # returns an array as one object; do not wrap in @()
    foreach ($l in @($leaves | Where-Object { $_.IsLink })) { Note "WARN link folder ignored (Claude cannot save into it): $($l.Path)" }
    $leaves = @($leaves | Where-Object { -not $_.IsLink })
    if ($leaves.Count -lt 2) { Note "nothing to sync ($($leaves.Count) folder)"; return }

    $day = Get-Date -Format 'yyyyMMdd'
    $stamp = Get-Date -Format 'HHmmss_fff'
    $dayDir = Join-Path $BackupRoot $day

    # --- daily snapshot of every card (first run of the day), prune old days
    if (-not (Test-Path -LiteralPath (Join-Path $dayDir 'snapshot'))) {
        foreach ($l in $leaves) {
            $dst = Join-Path $dayDir ('snapshot\' + ($l.Rel -replace '\\', '__'))
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
            foreach ($f in @(Get-ChildItem -LiteralPath $l.Path -Filter 'local_*.json' -Force -ErrorAction SilentlyContinue)) {
                try { [IO.File]::WriteAllBytes((Join-Path $dst $f.Name), (Read-SharedBytes $f.FullName)) } catch { Note "WARN snapshot skipped $($f.FullName): $($_.Exception.Message)" }
            }
        }
        # retention: daily snapshots 14 days, replaced copies 3 days, whole folder at most 300 MB
        $days = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}$' } | Sort-Object Name)
        foreach ($d in $days) {
            if ($d.Name -lt (Get-Date).AddDays(-14).ToString('yyyyMMdd')) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue; continue }
            if ($d.Name -lt (Get-Date).AddDays(-3).ToString('yyyyMMdd')) { Remove-Item -LiteralPath (Join-Path $d.FullName 'replaced') -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $days = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}$' -and $_.Name -ne $day } | Sort-Object Name)
        $total = (Get-ChildItem -LiteralPath $BackupRoot -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        foreach ($d in $days) {
            if ($total -le 300MB) { break }
            $size = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
            $total -= $size
        }
    }

    # one copy per distinct content: the same old card replaced in several folders is kept once
    function Keep-Copy([byte[]]$bytes, [string]$name, [string]$rel) {
        $dst = Join-Path $dayDir 'replaced'
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        $h = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').Substring(0, 12)
        $file = Join-Path $dst (([IO.Path]::GetFileNameWithoutExtension($name)) + '_' + $h + '.json')
        if (-not (Test-Path -LiteralPath $file)) { [IO.File]::WriteAllBytes($file, $bytes) }
    }
    function Write-Atomic([byte[]]$bytes, [datetime]$mtimeUtc, [string]$dst) {
        # temp name the app ignores (it recovers local_*.json.tmp files itself)
        $tmp = Join-Path ([IO.Path]::GetDirectoryName($dst)) ('.cssync-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllBytes($tmp, $bytes)
            [IO.File]::SetLastWriteTimeUtc($tmp, $mtimeUtc)   # keep the winner's time so the merge stays stable
            if (Test-Path -LiteralPath $dst) {
                try { [IO.File]::Replace($tmp, $dst, [NullString]::Value) }   # [NullString]: $null would become "" (invalid path)
                catch {
                    # with no backup file, a failed replace can leave the target deleted: put the new copy in place
                    if (-not (Test-Path -LiteralPath $dst) -and (Test-Path -LiteralPath $tmp)) { [IO.File]::Move($tmp, $dst) } else { throw }
                }
            } else { [IO.File]::Move($tmp, $dst) }
        } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
    }
    function Ms([datetime]$t) { [int64]([DateTimeOffset]$t.ToUniversalTime()).ToUnixTimeMilliseconds() }

    # --- read every card and tombstone once (shared read, so the app is never blocked)
    $cards = @{}        # id -> list of @{ Leaf; Path; Bytes; Hash; Info }
    $tombs = @{}        # id -> list of @{ Leaf; Path; Time }
    $noWrite = @{}      # "leafPath|id" -> card exists there but could not be read: leave it alone
    $badLeaf = @{}      # leafPath -> folder could not be listed: leave it alone
    $sha = [Security.Cryptography.SHA256]::Create()
    foreach ($l in $leaves) {
        $files = $null
        try { $files = @(Get-ChildItem -LiteralPath $l.Path -Force -File -ErrorAction Stop) }
        catch { $badLeaf[$l.Path] = $true; Note "WARN cannot list $($l.Path): $($_.Exception.Message)"; continue }
        foreach ($f in $files) {
            if ($f.Name -like 'local_*.json') {
                $id = $f.BaseName.Substring(6)
                $bytes = $null; $wt = $null
                try {
                    # time before and after the read must match, or the app saved in between: read again
                    for ($k = 0; $k -lt 3; $k++) {
                        $t0 = [IO.File]::GetLastWriteTimeUtc($f.FullName)
                        $bytes = Read-SharedBytes $f.FullName
                        $wt = [IO.File]::GetLastWriteTimeUtc($f.FullName)
                        if ($wt -eq $t0) { break }
                        if ($k -eq 2) { throw 'card kept changing while being read' }
                    }
                }
                catch { $noWrite["$($l.Path)|$id"] = $true; Note "WARN unreadable (locked?) $($f.FullName)"; continue }
                if (-not $cards.ContainsKey($id)) { $cards[$id] = @() }
                $cards[$id] += [pscustomobject]@{ Leaf = $l; Path = $f.FullName; Bytes = $bytes; Hash = [BitConverter]::ToString($sha.ComputeHash($bytes)); Info = $null; WriteTime = $wt }
            } elseif ($f.Name -like 'deleted_*') {
                $id = $f.Name.Substring(8)
                $t = Ms $f.LastWriteTime
                try { $v = [IO.File]::ReadAllText($f.FullName).Trim(); if ($v -match '^\d{12,14}$') { $t = [int64]$v } } catch {}
                if (-not $tombs.ContainsKey($id)) { $tombs[$id] = @() }
                $tombs[$id] += [pscustomobject]@{ Leaf = $l; Path = $f.FullName; Time = $t }
            }
        }
    }
    $writable = @($leaves | Where-Object { -not $badLeaf.ContainsKey($_.Path) })

    $copied = 0; $updated = 0; $removed = 0; $errors = 0
    foreach ($id in @($cards.Keys)) {
        $copies = @($cards[$id])
        $locked = @($leaves | Where-Object { $noWrite.ContainsKey("$($_.Path)|$id") }).Count
        # fast path: every folder already holds the identical card and nobody deleted it
        if ($locked -eq 0 -and $copies.Count -eq $leaves.Count -and @($copies | ForEach-Object { $_.Hash } | Sort-Object -Unique).Count -eq 1 -and -not $tombs.ContainsKey($id)) { continue }
        foreach ($c in $copies) {
            $c.Info = Get-RecordInfoFromBytes $c.Bytes $c.WriteTime
            # unreadable and changed in the last 15 s: probably being written right now (the app can
            # fall back to a non-atomic write). Leave it alone this run; the follow-up looks again.
            # Only a card that stays unreadable is treated as damaged and repaired from a good copy.
            if (-not $c.Info.Usable -and $c.WriteTime -gt [datetime]::UtcNow.AddSeconds(-15)) { $noWrite["$($c.Leaf.Path)|$id"] = $true }
        }
        $win = Select-BestCopy $copies
        if ($win -eq $null) { continue }   # nothing the app could read; leave as is
        $winTime = [Math]::Max($win.Info.Activity, (Ms $win.WriteTime))

        # deleted after the best card was last touched -> delete everywhere
        $newestTomb = $null
        if ($tombs.ContainsKey($id)) { $newestTomb = @($tombs[$id] | Sort-Object Time -Descending)[0] }
        if ($newestTomb -and $newestTomb.Time -ge $winTime) {
            foreach ($c in $copies) {
                if ($badLeaf.ContainsKey($c.Leaf.Path)) { continue }
                try { Keep-Copy $c.Bytes ("local_$id.json") $c.Leaf.Rel; Remove-Item -LiteralPath $c.Path -Force; $removed++; Note "removed (deleted elsewhere) $($c.Leaf.Rel)\local_$id.json" }
                catch { $errors++; Note "ERROR removing $($c.Path): $($_.Exception.Message)" }
            }
            foreach ($l in $writable) {
                $tp = Join-Path $l.Path ('deleted_' + $id)
                if (-not (Test-Path -LiteralPath $tp)) { try { Copy-Item -LiteralPath $newestTomb.Path -Destination $tp } catch { $errors++ } }
            }
            continue
        }

        # otherwise the best card goes everywhere
        foreach ($l in $writable) {
            if ($noWrite.ContainsKey("$($l.Path)|$id")) { continue }       # its copy could not be read: never overwrite it blind
            $dst = Join-Path $l.Path ("local_$id.json")
            $have = $copies | Where-Object { $_.Leaf.Path -eq $l.Path } | Select-Object -First 1
            if ($have -and $have.Hash -eq $win.Hash) { continue }
            $tp = Join-Path $l.Path ('deleted_' + $id)
            $known = @($tombs[$id] | Where-Object { $_ -and $_.Leaf.Path -eq $l.Path })
            if ((Test-Path -LiteralPath $tp) -and $known.Count -eq 0) { continue }   # deleted this very moment: the next run settles it
            try {
                if ($have) { Keep-Copy $have.Bytes ("local_$id.json") $l.Rel }
                Write-Atomic $win.Bytes $win.WriteTime $dst
                if ($have) { $updated++; Detail "updated $($l.Rel)\local_$id.json" } else { $copied++; Detail "added   $($l.Rel)\local_$id.json" }
                foreach ($t in $known) {   # an older deletion that would hide the card again
                    if ($t.Time -lt $winTime -and (Test-Path -LiteralPath $t.Path)) {
                        Keep-Copy ([IO.File]::ReadAllBytes($t.Path)) ([IO.Path]::GetFileName($t.Path)) $l.Rel
                        Remove-Item -LiteralPath $t.Path -Force
                    }
                }
            } catch { $errors++; Note "ERROR writing $dst : $($_.Exception.Message)" }
        }
    }
    Note ("synced {0} folders, {1} sessions: added {2}, updated {3}, removed {4}, errors {5}{6}" -f $leaves.Count, $cards.Count, $copied, $updated, $removed, $errors, $(if ($Delayed) { ' (follow-up)' } else { '' }))
}

function Invoke-Locked {
    $mutex = New-Object Threading.Mutex($false, 'Local\claude-session-sync')
    $owned = $false
    try { $owned = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { Note 'WARN another sync is still running; skipped'; return }
    try { Invoke-Sync } finally { $mutex.ReleaseMutex() }
}

try {
    . (Join-Path $PSScriptRoot 'common.ps1')
    $BackupRoot = Get-AbsolutePath $BackupRoot
    if ($RootsList) { $SessionRoots = @($RootsList -split '\|' | Where-Object { $_ }) }
    if ($Delayed) {
        Start-Sleep -Seconds 3; Invoke-Locked
        Start-Sleep -Seconds 7; Invoke-Locked
    } else {
        Invoke-Locked
        if ($Followup) {
            # a short-lived helper (about 12 s) that catches the card update Claude Desktop writes after the hook
            $args2 = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"'), '-Delayed', '-BackupRoot', ('"' + $BackupRoot + '"'))
            if ($SessionRoots) { $args2 += @('-RootsList', ('"' + ($SessionRoots -join '|') + '"')) }
            Start-Process -FilePath 'powershell.exe' -ArgumentList $args2 -WindowStyle Hidden | Out-Null
        }
    }
} catch {
    Note ("ERROR " + $_.Exception.Message)
} finally {
    try {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
        $logFile = Join-Path $BackupRoot 'sync.log'
        if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 1MB) { Move-Item -LiteralPath $logFile -Destination ($logFile + '.old') -Force }
        $lines = @($script:log | ForEach-Object { (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $_ })
        if ($lines.Count -gt 0) { [IO.File]::AppendAllText($logFile, (($lines -join "`r`n") + "`r`n")) }
    } catch {}
    # print nothing as a hook: a SessionStart hook's stdout would be added to Claude's context (tokens).
    # The log file has every line; -Verbose2 prints them for people running it by hand.
}
exit 0   # a hook must never block Claude
