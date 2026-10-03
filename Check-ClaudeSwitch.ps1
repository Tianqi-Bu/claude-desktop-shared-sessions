# Health check after switching account / third-party provider. Read-only; safe to run
# while Claude Desktop is open.
#   powershell -ExecutionPolicy Bypass -File .\Check-ClaudeSwitch.ps1
# Prints PASS / WARN / FAIL per check; exits 1 if anything FAILed.

param([string[]]$SessionRoots)   # optional: override root discovery (used by the tests)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
$script:fail = 0
function Say($level, $name, $detail) {
    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$level]
    Write-Host ("{0}  {1}  {2}" -f $level, $name, $detail) -ForegroundColor $color
    if ($level -eq 'FAIL') { $script:fail++ }
}

# 1. one shared session list
$roots = @()
try { $roots = Resolve-SessionRoots $(if ($PSBoundParameters.ContainsKey('SessionRoots')) { $SessionRoots } else { Get-DefaultSessionRoots }) }
catch { Say FAIL 'session roots' $_.Exception.Message }
$leaves = @(); if ($roots.Count -gt 0) { $leaves = Get-Leaves $roots }
$real  = @($leaves | Where-Object { -not $_.IsLink })
$links = @($leaves | Where-Object { $_.IsLink })
if ($leaves.Count -eq 0) {
    Say FAIL 'session folders' 'none found (open the Code tab once)'
} elseif ($real.Count -eq 0) {
    Say FAIL 'shared list missing' ("every login is a link but the folder they point at is gone: " + (@($links | ForEach-Object { $_.Target } | Sort-Object -Unique) -join ', ') + ". " + $script:MissingListHelp)
} elseif ($real.Count -eq 1) {
    $master = $real[0].Path
    Say PASS 'one shared list' ("{0} sessions in {1}" -f $real[0].Count, $master)
    foreach ($l in $links) {
        if (-not (Test-Path -LiteralPath $l.Path)) { Say FAIL 'link' "$($l.Path) is broken (target missing)" }
        elseif ($l.Target -ine $master) { Say FAIL 'link' "$($l.Path) points at $($l.Target), not the shared list" }
        else { Say PASS 'link' "$($l.Rel) -> shared list" }
    }
} else {
    Say FAIL 'one shared list' ("{0} separate lists; quit Claude and run Link-ClaudeAccounts.ps1 -Apply" -f $real.Count)
    foreach ($l in $links | Where-Object { -not (Test-Path -LiteralPath $_.Path) }) { Say FAIL 'link' "$($l.Path) is broken (target missing)" }
}

# records the app cannot use: unreadable (BOM/empty/invalid) or unlinked from their transcript
$recs = @($real | ForEach-Object { Get-ChildItem -LiteralPath $_.Path -Filter 'local_*.json' -Force })
$info = @($recs | ForEach-Object { Get-RecordInfo $_.FullName })
$bad = @($info | Where-Object { -not $_.Usable }).Count
$unlinked = @($info | Where-Object { $_.Usable -and -not $_.Healthy }).Count
if ($bad -gt 0) { Say WARN 'unreadable records' "$bad session file(s) the app will skip (UTF-8 BOM, empty or not JSON)" }
if ($unlinked -gt 0) { Say WARN 'unlinked records' "$unlinked session(s) no longer point at a transcript and will not open (anthropics/claude-code#63082)" }

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

Write-Host ""
if ($script:fail -eq 0) { Write-Host "No failures." -ForegroundColor Green; exit 0 } else { Write-Host "$script:fail failure(s)." -ForegroundColor Red; exit 1 }
