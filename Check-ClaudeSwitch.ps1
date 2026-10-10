# Health check after switching account / third-party provider. Read-only; safe to run
# while Claude Desktop is open.
#   powershell -ExecutionPolicy Bypass -File .\Check-ClaudeSwitch.ps1
# Prints PASS / WARN / FAIL per check; exits 1 if anything FAILed.

param(
    [string[]]$SessionRoots,   # optional: override root discovery (used by the tests)
    [string]$ClaudeCommand,    # optional: the claude CLI to run 'doctor' with (default: claude on PATH)
    [switch]$SkipDoctor,       # skip the 'claude doctor' settings check
    [string[]]$DesktopLog,     # optional: Claude Desktop logs (default main.log/main1.log of the official and Claude-3p profiles)
    [int]$LogHours = 24,       # look for failed saves in this many recent hours
    [string]$ProjectsDir,      # optional: transcripts folder (default ~\.claude\projects)
    [int]$LostDays = 30,       # look for conversations without a card this many days back
    [switch]$SkipSyncHook      # skip the check that the sync hook is installed
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
$script:fail = 0
function Say($level, $name, $detail) {
    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$level]
    Write-Host ("{0}  {1}  {2}" -f $level, $name, $detail) -ForegroundColor $color
    if ($level -eq 'FAIL') { $script:fail++ }
}

# 1. every login has a real folder (Claude Desktop refuses to save into links) and all hold the same cards
$roots = @()
try { $roots = Resolve-SessionRoots $(if ($PSBoundParameters.ContainsKey('SessionRoots')) { $SessionRoots } else { Get-DefaultSessionRoots }) }
catch { Say FAIL 'session roots' $_.Exception.Message }
$leaves = @(); if ($roots.Count -gt 0) { $leaves = Get-Leaves $roots }
$real  = @($leaves | Where-Object { -not $_.IsLink })
$links = @($leaves | Where-Object { $_.IsLink })
if ($leaves.Count -eq 0) { Say FAIL 'session folders' 'none found (open the Code tab once)' }
foreach ($l in $links) { Say FAIL 'link folder' "$($l.Path) is a link; Claude Desktop refuses to save sessions into it. Replace it with a real folder (Unlink-ClaudeAccounts.ps1 -Apply with Claude quit)." }
# every card in every folder, read once
$byId = @{}; $hasTomb = @{}; $hasTombAny = @{}; $newestCard = [datetime]::MinValue
foreach ($l in $real) {
    foreach ($f in @(Get-ChildItem -LiteralPath $l.Path -Force -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -like 'deleted_*') { $hasTomb["$($l.Path)|$($f.Name.Substring(8))"] = $true; $hasTombAny[$f.Name.Substring(8)] = $true; continue }
        if ($f.Name -notlike 'local_*.json') { continue }
        $id = $f.BaseName.Substring(6)
        $bytes = [byte[]]@(); try { $bytes = Read-SharedBytes $f.FullName } catch {}
        $i = Get-RecordInfoFromBytes $bytes $f.LastWriteTimeUtc
        $h = ''; try { $h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) } catch {}
        if (-not $byId.ContainsKey($id)) { $byId[$id] = @() }
        $byId[$id] += [pscustomobject]@{ Leaf = $l.Path; Info = $i; Hash = $h }
        if ($f.LastWriteTime -gt $newestCard) { $newestCard = $f.LastWriteTime }
    }
}
# a session missing from a login (and not deleted there) means that login shows an incomplete list
$missing = 0; $differ = 0
foreach ($id in $byId.Keys) {
    $in = @($byId[$id] | ForEach-Object { $_.Leaf })
    foreach ($l in $real) { if ($in -notcontains $l.Path -and -not $hasTomb.ContainsKey("$($l.Path)|$id")) { $missing++; break } }
    if (@($byId[$id] | ForEach-Object { $_.Hash } | Sort-Object -Unique).Count -gt 1) { $differ++ }
}
$fresh = $newestCard -gt (Get-Date).AddSeconds(-20)
if ($real.Count -eq 0) { }
elseif ($missing -gt 0 -and -not $fresh) { Say FAIL 'same list everywhere' ("{0} session(s) are missing from at least one login; run Sync-ClaudeSessions.ps1 (or the desktop shortcut) before switching" -f $missing) }
elseif ($missing -gt 0 -or $differ -gt 0) { Say WARN 'same list everywhere' ("{0} missing / {1} different card(s) across {2} logins; a sync is due (it runs when a Claude turn ends, or use the desktop shortcut)" -f $missing, $differ, $real.Count) }
else { Say PASS 'same list everywhere' ("{0} login folder(s), {1} sessions each" -f $real.Count, $byId.Count) }

# cards the app cannot use, counted once per session
$bad = @($byId.Keys | Where-Object { -not @($byId[$_] | Where-Object { $_.Info.Usable }).Count }).Count
$unlinked = @($byId.Keys | Where-Object { $u = @($byId[$_] | Where-Object { $_.Info.Usable }); $u.Count -and -not @($u | Where-Object { -not $_.Info.Damaged }).Count }).Count
if ($bad -gt 0) { Say WARN 'unreadable records' "$bad session file(s) the app will skip (UTF-8 BOM, empty or not JSON)" }
if ($unlinked -gt 0) { Say WARN 'unlinked records' "$unlinked session(s) are marked transcriptUnavailable and will not open (anthropics/claude-code#63082)" }

# 1b. did Claude Desktop fail to save any session card recently? (this is how cards get lost)
#     Failures caused by a link folder that has since been replaced by a real folder are history.
if (-not $DesktopLog) {
    $DesktopLog = @('Claude\Logs\main.log', 'Claude\Logs\main1.log', 'Claude-3p\logs\main.log', 'Claude-3p\logs\main1.log') | ForEach-Object { Join-Path $env:LOCALAPPDATA $_ }
}
$logs = @($DesktopLog | Where-Object { Test-Path -LiteralPath $_ })
if ($logs.Count -gt 0) {
    $since = (Get-Date).AddHours(-$LogHours).ToString('yyyy-MM-dd HH:mm:ss')
    $fails = @($logs | ForEach-Object { Select-String -LiteralPath $_ -Pattern 'Failed to save session (local_[0-9a-f-]{36})' -ErrorAction SilentlyContinue } |
        Where-Object { $_.Line.Length -ge 19 -and $_.Line.Substring(0, 19) -ge $since })
    $current = @(); $history = 0
    foreach ($fl in $fails) {
        $m = [regex]::Match($fl.Line, 'plant\): (.+?)\s+\{')
        $when = [datetime]::MinValue; [void][datetime]::TryParse($fl.Line.Substring(0, 19), [ref]$when)
        if ($m.Success -and (Test-Path -LiteralPath $m.Groups[1].Value)) {
            $it = Get-Item -LiteralPath $m.Groups[1].Value -Force
            if (-not ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $it.CreationTime -gt $when) { $history++; continue }
        }
        $current += $fl
    }
    if ($current.Count -gt 0) {
        $ids = @($current | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique)
        Say FAIL 'desktop saves' ("Claude Desktop failed to save {0} time(s) in the last {1}h ({2} session(s)); last: {3}" -f $current.Count, $LogHours, $ids.Count, $current[-1].Line.Substring(0, [Math]::Min(220, $current[-1].Line.Length)))
    } elseif ($history -gt 0) { Say PASS 'desktop saves' "no new failures; $history older failure(s) in the last ${LogHours}h came from link folders that are now real folders" }
    else { Say PASS 'desktop saves' "no failed session saves in the last ${LogHours}h" }
}

# 1c. Desktop conversations whose card is gone from every login (the conversation is still on disk)
if (-not $ProjectsDir) { $ProjectsDir = Join-Path $env:USERPROFILE '.claude\projects' }
if ((Test-Path -LiteralPath $ProjectsDir) -and $real.Count -gt 0) {
    $refs = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($l in $real) { foreach ($f in @(Get-ChildItem -LiteralPath $l.Path -Filter 'local_*.json' -Force -ErrorAction SilentlyContinue)) {
        $t = ''; try { $t = [IO.File]::ReadAllText($f.FullName) } catch {}
        foreach ($m in [regex]::Matches($t, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')) { [void]$refs.Add($m.Value) }
    } }
    $cut = (Get-Date).AddDays(-$LostDays)
    $orphans = @()
    foreach ($tf in @(Get-ChildItem -LiteralPath $ProjectsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue } | Where-Object { $_.LastWriteTime -gt $cut })) {
        if ($refs.Contains($tf.BaseName)) { continue }
        if ($hasTombAny.ContainsKey($tf.BaseName)) { continue }   # deleted on purpose (the app writes deleted_<id>)
        # a Desktop conversation with at least one reply; replies can start megabytes in
        # (large attachments come first), so read in chunks until both markers are seen
        $desk = $false; $reply = $false
        try {
            $sr = New-Object IO.StreamReader($tf.FullName); $buf = New-Object char[] 1048576; $carry = ''
            for ($k = 0; $k -lt 16 -and -not ($desk -and $reply); $k++) {
                $n = $sr.Read($buf, 0, $buf.Length); if ($n -le 0) { break }
                $chunk = $carry + (New-Object string($buf, 0, $n))
                if (-not $desk -and $chunk -match '"entrypoint"\s*:\s*"claude-desktop') { $desk = $true }
                if (-not $reply -and $chunk -match '"type"\s*:\s*"assistant"') { $reply = $true }
                $carry = $chunk.Substring([Math]::Max(0, $chunk.Length - 64))
            }
            $sr.Close()
        } catch {}
        if ($desk -and $reply) { $orphans += $tf }
    }
    if ($orphans.Count -gt 0) {
        Say WARN 'conversations without a card' ("{0} Desktop conversation(s) from the last {1} days have no sidebar card (newest: {2}, {3}). Recover one with: claude --desktop --resume <id>  (run in a normal terminal window; Help > Troubleshooting > Import only finds sessions started in the terminal)." -f $orphans.Count, $LostDays, ($orphans | Sort-Object LastWriteTime -Descending | Select-Object -First 1).BaseName.Substring(0, 8), ($orphans | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime.ToString('MM-dd HH:mm'))
    } else { Say PASS 'conversations without a card' "every Desktop conversation from the last $LostDays days has a card" }
}

# every login must read the same ~/.claude
foreach ($scope in 'User', 'Machine', 'Process') {
    $v = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', $scope)
    if ($v) { Say WARN 'CLAUDE_CONFIG_DIR' "set ($scope) to $v; every login must use the same config folder or shared sessions break" }
}

# 2. conversations are not on a short cleanup timer (default is 30 days)
$sjPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$sj = $null
try { $sj = [IO.File]::ReadAllText($sjPath) } catch {}
if (-not $sj) { Say WARN 'settings.json' "not found or unreadable: $sjPath" }
elseif ($sj -match '"cleanupPeriodDays"\s*:\s*(\d+)' -and [int]$Matches[1] -ge 365) { Say PASS 'transcript retention' "cleanupPeriodDays=$($Matches[1])" }
else { Say WARN 'transcript retention' 'cleanupPeriodDays is unset or short; old conversations are deleted after 30 days by default' }

# 2b. the sync hook that keeps every login's list the same
if (-not $SkipSyncHook -and $sj) {
    if ($sj -match 'Sync-ClaudeSessions\.ps1') { Say PASS 'sync hook' 'installed in settings.json' }
    else { Say WARN 'sync hook' 'not in settings.json; logins will drift apart (run Install-SyncHook.ps1)' }
    $syncLog = Join-Path $env:USERPROFILE 'claude-session-sync-backup\sync.log'
    if (Test-Path -LiteralPath $syncLog) {
        $last = @(Get-Content -LiteralPath $syncLog -Tail 40 -ErrorAction SilentlyContinue)
        $lastRun = @($last | Where-Object { $_ -match '  synced ' }) | Select-Object -Last 1
        $lastErr = @($last | Where-Object { $_ -match '  ERROR ' }) | Select-Object -Last 1
        if ($lastRun) {
            $lt = [datetime]::MinValue; [void][datetime]::TryParse($lastRun.Substring(0, 19), [ref]$lt)
            if ($newestCard -gt $lt.AddSeconds(15)) { Say WARN 'last sync' ("a card changed at {0}, after the last sync ({1}); it syncs when a Claude turn ends, or use the desktop shortcut" -f $newestCard.ToString('HH:mm:ss'), $lt.ToString('HH:mm:ss')) }
            else { Say PASS 'last sync' $lastRun.Trim() }
        }
        if ($lastErr -and (-not $lastRun -or $lastErr.Substring(0, 19) -ge $lastRun.Substring(0, 19))) { Say WARN 'last sync' $lastErr.Trim() }
    }
}

# 3. CC Switch: settings it manages must survive a provider switch (needs python for sqlite)
$db = Join-Path $env:USERPROFILE '.cc-switch\cc-switch.db'
$py = Get-Command python -ErrorAction SilentlyContinue
if ((Test-Path -LiteralPath $db) -and $sj) {
    if (-not $py) { Say WARN 'CC Switch checks' 'python not found; skipped' }
    else {
        $code = @'
import sqlite3, json, sys, pathlib
c = sqlite3.connect(pathlib.Path(sys.argv[1]).as_uri() + '?mode=ro', uri=True)
off = [n for n, m in c.execute("select name, meta from providers where app_type='claude'") if (json.loads(m) if m else {}).get('commonConfigEnabled') is not True]
row = c.execute("select value from settings where key='common_config_claude'").fetchone()
keys = sorted(json.loads(row[0]).keys()) if row and row[0] else []
print(json.dumps({'off': off, 'keys': keys}))
'@
        # run from a file: PowerShell 5.1 mangles quotes in arguments passed to native programs
        $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), ('cslink-check-' + [guid]::NewGuid().ToString('N') + '.py'))
        [IO.File]::WriteAllText($tmp, $code, (New-Object Text.UTF8Encoding $false))
        $out = $null
        try { $out = (& $py.Source $tmp $db 2>$null) | Select-Object -Last 1 } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        $res = $null
        try { $res = $out | ConvertFrom-Json } catch {}
        if (-not $res) { Say WARN 'CC Switch checks' 'could not read the CC Switch database; skipped' }
        else {
            if (@($res.off).Count -gt 0) { Say WARN 'CC Switch common config' ("not enabled on: " + (@($res.off) -join '; ') + " (switching to these wipes your plugins/hooks/permissions)") }
            else { Say PASS 'CC Switch common config' 'enabled on every Claude provider' }
            $missing = @(@($res.keys) | Where-Object { $sj -notmatch ('"' + [regex]::Escape($_) + '"\s*:') })
            if ($missing.Count -gt 0) { Say FAIL 'settings.json intact' ("missing from settings.json: " + ($missing -join ', ')) }
            elseif (@($res.keys).Count -gt 0) { Say PASS 'settings.json intact' "$(@($res.keys).Count) shared keys present" }
        }
    }
}

# 4. Claude Code must accept settings.json. If any value is invalid, Claude Code ignores the
#    whole file, which silently disables every plugin, hook and permission in it.
#    'claude doctor' lists such errors under "Invalid settings".
if (-not $SkipDoctor) {
    $exe = $ClaudeCommand
    if (-not $exe) {
        $c = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { $exe = $c.Source }
    }
    if (-not $exe) { Say WARN 'settings valid' "claude CLI not found on PATH; could not run 'claude doctor'" }
    else {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $exe; $psi.Arguments = 'doctor'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $text = $null
        try {
            $proc = [Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $so = $proc.StandardOutput.ReadToEndAsync(); $se = $proc.StandardError.ReadToEndAsync()
            if ($proc.WaitForExit(90000)) { $text = $so.Result + "`n" + $se.Result }
            else { try { $proc.Kill() } catch {} }
        } catch {}
        if ($text -eq $null) { Say WARN 'settings valid' "'claude doctor' did not run or did not finish; skipped" }
        else {
            $lines = @(($text -replace "\x1b\[[0-9;?]*[A-Za-z]", '') -split "`r?`n" | ForEach-Object { $_.Trim() })
            $at = [Array]::IndexOf($lines, 'Invalid settings')
            if ($at -ge 0) {
                $bad = @()
                for ($i = $at + 1; $i -lt $lines.Count -and $lines[$i].StartsWith('-'); $i++) { $bad += $lines[$i].TrimStart('-', ' ') }
                Say FAIL 'settings valid' ("Claude Code ignores your settings file (plugins, hooks and permissions are off): " + ($bad -join '; '))
            } elseif ($text -match '(?i)doctor') {
                Say PASS 'settings valid' "'claude doctor' reports no invalid settings"
            } else {
                Say WARN 'settings valid' "unexpected output from 'claude doctor'; skipped"
            }
        }
    }
}

Write-Host ""
if ($script:fail -eq 0) { Write-Host "No failures." -ForegroundColor Green; exit 0 } else { Write-Host "$script:fail failure(s)." -ForegroundColor Red; exit 1 }
