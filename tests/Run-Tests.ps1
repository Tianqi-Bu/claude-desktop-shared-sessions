# Self-contained tests: build fake Claude session folders under %TEMP%, run the scripts
# against them, and assert the results. Never touches real Claude data.
#   powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$sync = Join-Path $repo 'Sync-ClaudeSessions.ps1'
$unlink = Join-Path $repo 'Unlink-ClaudeAccounts.ps1'
$check = Join-Path $repo 'Check-ClaudeSwitch.ps1'
$utf8 = New-Object Text.UTF8Encoding $false

$script:passed = 0; $script:failed = 0; $script:dirs = @()
function Assert($cond, $msg) {
    if ($cond) { $script:passed++; Write-Host "  ok    $msg" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  FAIL  $msg" -ForegroundColor Red }
}
function Run([string]$script, [hashtable]$params) {
    $global:LASTEXITCODE = 0
    $out = try { & $script @params *>&1 | Out-String -Width 4096 } catch { "THROWN: " + $_.Exception.Message }
    return @{ Out = $out; Code = $global:LASTEXITCODE }
}
function U([string]$c) { "$c$c$c$c$c$c$c$c-0000-4000-8000-00000000000$c" }
function Rec($dir, $id, $activity, [switch]$Damaged, [switch]$Bom, $Title = 't', [switch]$Truncated, [string]$Cli, [string]$Extra) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $link = if ($Damaged) { '"transcriptUnavailable":true' } elseif ($Cli -eq 'none') { '"preClear":0' } elseif ($Cli) { '"cliSessionId":"' + $Cli + '"' } else { '"cliSessionId":"' + $id + '"' }
    if ($Extra) { $link += ',' + $Extra }
    $json = '{"sessionId":"local_' + $id + '",' + $link + ',"title":"' + $Title + '","lastActivityAt":' + $activity + '}'
    if ($Truncated) { $json = $json.Substring(0, $json.Length - 8) }
    $enc = if ($Bom) { New-Object Text.UTF8Encoding $true } else { $utf8 }
    $p = Join-Path $dir "local_$id.json"
    [IO.File]::WriteAllText($p, $json, $enc)
    return $p
}
function Field($dir, $id, $name) {
    # read the way the app does (sharing read/write/delete), retrying across a concurrent replace
    $p = Join-Path $dir "local_$id.json"
    for ($k = 0; $k -lt 20; $k++) {
        if (-not (Test-Path -LiteralPath $p)) { Start-Sleep -Milliseconds 50; continue }
        try {
            $fs = New-Object IO.FileStream($p, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try { $t = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
            return [regex]::Match($t, '"' + $name + '":"?([^",}]*)').Groups[1].Value
        } catch { Start-Sleep -Milliseconds 50 }
    }
    return $null
}
function Has($dir, $id) { Test-Path -LiteralPath (Join-Path $dir "local_$id.json") }
function Names($dir) { @(Get-ChildItem -LiteralPath $dir -Filter 'local_*.json' -Force | ForEach-Object Name | Sort-Object) }
function IsLink($p) { $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; [bool]($i -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) }
function Snapshot($dir) { (Get-ChildItem -LiteralPath $dir -Recurse -Force | ForEach-Object { $_.FullName + '|' + $(if ($_.PSIsContainer) { 'd' } else { $_.Length.ToString() + (Get-FileHash -LiteralPath $_.FullName).Hash }) }) -join "`n" }
function Tomb($dir, $id, [int64]$ms) { [IO.File]::WriteAllText((Join-Path $dir "deleted_$id"), [string]$ms) }
function NowMs { [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }
# a fresh fake machine: official root with accounts A and B, third-party root with P
function New-Fixture([string]$tag = '') {
    $b = Join-Path $env:TEMP ("cssync-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + $tag)
    $script:dirs += $b
    $f = @{ Base = $b; R1 = (Join-Path $b 'official\claude-code-sessions'); R2 = (Join-Path $b 'thirdparty\claude-code-sessions') }
    $f.A = Join-Path $f.R1 ((U 'a') + '\' + (U 'b'))
    $f.B = Join-Path $f.R1 ((U 'c') + '\' + (U 'd'))
    $f.P = Join-Path $f.R2 ((U 'e') + '\' + (U 'f'))
    foreach ($d in $f.A, $f.B, $f.P) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $f.Roots = @($f.R1, $f.R2)
    $f.Bk = Join-Path $b 'sync-backup'
    return $f
}
function SyncIt($f) { Run $sync @{ SessionRoots = $f.Roots; BackupRoot = $f.Bk; Verbose2 = $true } }
function CheckIt($f, [hashtable]$extra = @{}) {
    $p = @{ SessionRoots = $f.Roots; SkipDoctor = $true; SkipSyncHook = $true; DesktopLog = (Join-Path $f.Base 'no.log'); ProjectsDir = (Join-Path $f.Base 'no-projects') }
    foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] }
    Run $check $p
}

try {
    Write-Host "`n[1] cards created in different logins end up in every login"
    $f = New-Fixture
    Rec $f.A (U '1') 100 | Out-Null; Rec $f.B (U '2') 100 | Out-Null; Rec $f.P (U '3') 100 | Out-Null
    $r = SyncIt $f
    Assert ($r.Code -eq 0) 'exit code 0'
    Assert ((Names $f.A).Count -eq 3 -and (Names $f.B).Count -eq 3 -and (Names $f.P).Count -eq 3) 'all three logins hold all three cards'
    Assert ($r.Out -match 'added 6') 'reports 6 cards added'
    $c = CheckIt $f
    Assert ($c.Out -match 'PASS  same list everywhere') 'check: same list everywhere'

    Write-Host "`n[2] the newer card wins everywhere and the replaced one is backed up"
    Rec $f.B (U '1') 900 -Title 'continued-in-B' | Out-Null
    $r = SyncIt $f
    Assert ((Field $f.A (U '1') 'title') -eq 'continued-in-B' -and (Field $f.P (U '1') 'title') -eq 'continued-in-B') 'newer card copied to the other logins'
    $kept = @(Get-ChildItem -LiteralPath $f.Bk -Recurse -Filter "local_$(U '1')_*.json" | Where-Object { $_.FullName -match '\\replaced\\' })
    Assert ($kept.Count -eq 1) 'replaced card kept in the backup once (identical copies deduplicated)'
    Assert (Test-Path -LiteralPath (Join-Path $f.Bk ((Get-Date -Format 'yyyyMMdd') + '\snapshot'))) 'daily snapshot written'

    Write-Host "`n[3] a second run changes nothing"
    $snap = (Snapshot $f.A) + (Snapshot $f.B) + (Snapshot $f.P)
    $r = SyncIt $f
    Assert ($r.Out -match 'added 0, updated 0, removed 0, errors 0') 'nothing to do'
    Assert (((Snapshot $f.A) + (Snapshot $f.B) + (Snapshot $f.P)) -eq $snap) 'no file touched'

    Write-Host "`n[4] same lastActivityAt: the more recently written card wins (rename / archive)"
    $p = Rec $f.P (U '1') 900 -Title 'renamed-in-3p'
    (Get-Item -LiteralPath $p).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(5)
    $r = SyncIt $f
    Assert ((Field $f.A (U '1') 'title') -eq 'renamed-in-3p' -and (Field $f.B (U '1') 'title') -eq 'renamed-in-3p') 'rename propagated'

    Write-Host "`n[5] a session deleted in one login is removed from the others"
    Remove-Item -LiteralPath (Join-Path $f.B ("local_$(U '2').json")); Tomb $f.B (U '2') ((NowMs) + 60000)
    $r = SyncIt $f
    Assert (-not (Has $f.A (U '2')) -and -not (Has $f.P (U '2'))) 'card removed everywhere'
    Assert ((Test-Path -LiteralPath (Join-Path $f.A "deleted_$(U '2')")) -and (Test-Path -LiteralPath (Join-Path $f.P "deleted_$(U '2')"))) 'tombstone copied everywhere'
    Assert (@(Get-ChildItem -LiteralPath $f.Bk -Recurse -Filter "local_$(U '2')_*.json" | Where-Object { $_.FullName -match '\\replaced\\' }).Count -eq 1) 'removed card kept in the backup once (identical copies deduplicated)'
    $r = SyncIt $f
    Assert (-not (Has $f.A (U '2'))) 'stays deleted on the next run'

    Write-Host "`n[6] a card changed after an old deletion comes back (re-imported session)"
    $f = New-Fixture
    Tomb $f.A (U '4') 1000
    Rec $f.B (U '4') 5000 | Out-Null
    $r = SyncIt $f
    Assert ((Has $f.A (U '4')) -and (Has $f.P (U '4'))) 'newer card restored in every login'
    Assert (-not (Test-Path -LiteralPath (Join-Path $f.A "deleted_$(U '4')"))) 'stale tombstone set aside'

    Write-Host "`n[7] healthy beats damaged; unreadable and truncated cards never spread or win"
    $f = New-Fixture
    Rec $f.A (U '1') 9000 -Damaged | Out-Null; Rec $f.B (U '1') 10 | Out-Null
    Rec $f.A (U '2') 10 | Out-Null; $pb = Rec $f.B (U '2') 9000 -Bom; (Get-Item -LiteralPath $pb).LastWriteTime = (Get-Date).AddHours(-1)
    Rec $f.A (U '3') 10 -Title 'GOOD' | Out-Null; $pt = Rec $f.B (U '3') 9000 -Truncated; (Get-Item -LiteralPath $pt).LastWriteTime = (Get-Date).AddHours(-1)
    Rec $f.P (U '5') 10 -Bom | Out-Null
    $r = SyncIt $f
    Assert ((Field $f.A (U '1') 'cliSessionId') -ne '' -and (Field $f.P (U '1') 'cliSessionId') -ne '') 'healthy older card replaced the damaged newer one'
    Assert ([IO.File]::ReadAllBytes((Join-Path $f.A "local_$(U '2').json"))[0] -eq 0x7B -and [IO.File]::ReadAllBytes((Join-Path $f.B "local_$(U '2').json"))[0] -eq 0x7B) 'readable card replaced the BOM copy'
    Assert ((Field $f.B (U '3') 'title') -eq 'GOOD') 'good card replaced the truncated copy'
    Assert (-not (Has $f.A (U '5'))) 'a card readable nowhere is not spread'

    Write-Host "`n[7b] a card being written right now (unreadable, just changed) is not overwritten"
    $f = New-Fixture
    Rec $f.A (U '1') 10 -Title 'old' | Out-Null
    Rec $f.B (U '1') 10 -Title 'old' | Out-Null
    Rec $f.B (U '1') 9000 -Title 'half-written' -Truncated | Out-Null
    $r = SyncIt $f
    Assert ([IO.File]::ReadAllText((Join-Path $f.B "local_$(U '1').json")) -match 'half-written') 'half-written card left alone'
    Rec $f.B (U '1') 9000 -Title 'finished' | Out-Null
    $r = SyncIt $f
    Assert ((Field $f.A (U '1') 'title') -eq 'finished' -and (Field $f.P (U '1') 'title') -eq 'finished') 'once complete it wins everywhere'

    Write-Host "`n[8] a link folder is never written into"
    $f = New-Fixture
    Rec $f.A (U '1') 1 | Out-Null
    $L = Join-Path $f.R1 ((U '9') + '\' + (U '9'))
    New-Item -ItemType Directory -Path (Split-Path $L -Parent) -Force | Out-Null
    $tgt = Join-Path $f.Base 'elsewhere'; New-Item -ItemType Directory -Path $tgt | Out-Null
    New-Item -ItemType Junction -Path $L -Target $tgt | Out-Null
    $r = SyncIt $f
    Assert ((Names $tgt).Count -eq 0) 'nothing written through the link'
    Assert ((Has $f.B (U '1')) -and (Has $f.P (U '1'))) 'real folders still synced'
    $c = CheckIt $f
    Assert ($c.Out -match 'FAIL  link folder' -and $c.Code -eq 1) 'check flags the link folder'
    $r = Run $unlink @{ SessionRoots = $f.Roots; Apply = $true }
    Assert (-not (IsLink $L)) 'unlink turns it into a real folder'

    Write-Host "`n[9] a locked card is skipped, the run still finishes with exit 0"
    $f = New-Fixture
    $p = Rec $f.A (U '1') 1; Rec $f.A (U '2') 1 | Out-Null
    $h = [IO.File]::Open($p, 'Open', 'Read', 'None')
    try { $r = SyncIt $f } finally { $h.Close() }
    Assert ($r.Code -eq 0) 'exit code 0'
    Assert ((Has $f.B (U '2')) -and (Has $f.P (U '2'))) 'the other card was synced'
    $r = SyncIt $f
    Assert ((Has $f.B (U '1'))) 'locked card synced once free'

    Write-Host "`n[10] a broken setup never makes the hook fail"
    $r = Run $sync @{ SessionRoots = @((Join-Path $env:TEMP ('cssync-missing-' + [guid]::NewGuid().ToString('N')))); BackupRoot = (Join-Path $f.Base 'bk2') }
    Assert ($r.Code -eq 0) 'missing roots: exit code 0'
    $junkRoot = Join-Path $f.Base 'junk\claude-code-sessions'; New-Item -ItemType Directory -Path (Split-Path $junkRoot -Parent) -Force | Out-Null
    New-Item -ItemType Junction -Path $junkRoot -Target $f.R1 | Out-Null
    $r = Run $sync @{ SessionRoots = @($junkRoot); BackupRoot = (Join-Path $f.Base 'bk3'); Verbose2 = $true }
    Assert ($r.Code -eq 0 -and $r.Out -match 'ERROR') 'linked root: logs an error, exit code 0'

    Write-Host "`n[11] paths with spaces, brackets and Chinese characters"
    $f = New-Fixture (' ' + [char]0x5F20 + [char]0x4E09 + ' [Work] (x)')
    Rec $f.A (U '1') 1 | Out-Null; Rec $f.P (U '2') 1 | Out-Null
    $r = SyncIt $f
    Assert ((Names $f.B).Count -eq 2 -and (Names $f.A).Count -eq 2) 'synced'

    Write-Host "`n[14] /clear and compaction: an out-of-date card never wins, even with a newer time"
    $f = New-Fixture
    $old = U '7'; $new = U '8'
    Rec $f.A (U '1') 2000 -Cli 'none' -Extra ('"preClearCliSessionId":"' + $old + '"') -Title 'cleared' | Out-Null
    Rec $f.B (U '1') 1000 -Cli $old -Title 'before-clear' | Out-Null
    Rec $f.P (U '1') 9000 -Cli $old -Title 'before-clear-newer-time' | Out-Null
    Rec $f.A (U '2') 1000 -Cli $new -Extra ('"priorCliSessionIds":["' + $old + '"]') -Title 'compacted' | Out-Null
    Rec $f.B (U '2') 5000 -Cli $old -Title 'pre-compaction' | Out-Null
    $r = SyncIt $f
    Assert ((Field $f.B (U '1') 'title') -eq 'cleared' -and (Field $f.P (U '1') 'title') -eq 'cleared') 'cleared card (no cliSessionId) wins over pre-clear copies'
    Assert ((Field $f.B (U '2') 'cliSessionId') -eq $new -and (Field $f.P (U '2') 'cliSessionId') -eq $new) 'compacted card wins; nobody resumes the old conversation file'
    $c = CheckIt $f
    Assert ($c.Out -notmatch 'unlinked records') 'a cleared card is not reported as broken'

    Write-Host "`n[15] the newest card held open by the app is still read; an unreadable one is never overwritten"
    $f = New-Fixture
    $pa = Rec $f.A (U '1') 9000 -Title 'newest'; Rec $f.B (U '1') 10 -Title 'old' | Out-Null
    $h = New-Object IO.FileStream($pa, 'Open', 'ReadWrite', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $r = SyncIt $f } finally { $h.Dispose() }
    Assert ((Field $f.B (U '1') 'title') -eq 'newest') 'card open for writing (shared) was read and won'
    $pa = Rec $f.A (U '2') 9000 -Title 'newest'; Rec $f.B (U '2') 10 -Title 'old' | Out-Null; Rec $f.P (U '2') 10 -Title 'old' | Out-Null
    $h = [IO.File]::Open($pa, 'Open', 'Read', 'None')
    try { $r = SyncIt $f } finally { $h.Close() }
    Assert ((Field $f.A (U '2') 'title') -eq 'newest') 'exclusively locked newest card was not overwritten'
    $r = SyncIt $f
    Assert ((Field $f.B (U '2') 'title') -eq 'newest') 'and it spreads once readable'

    Write-Host "`n[16] -Followup syncs again a few seconds later (the app writes the last card after the hook)"
    $f = New-Fixture
    Rec $f.A (U '1') 100 -Title 'during-turn' | Out-Null
    $r = Run $sync @{ SessionRoots = $f.Roots; BackupRoot = $f.Bk; Followup = $true }
    Assert ((Field $f.B (U '1') 'title') -eq 'during-turn') 'synced at once'
    Start-Sleep -Milliseconds 1500
    Rec $f.A (U '1') 200 -Title 'after-hook' | Out-Null
    $deadline = (Get-Date).AddSeconds(25)
    while (((Field $f.B (U '1') 'title') -ne 'after-hook' -or (Field $f.P (U '1') 'title') -ne 'after-hook') -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }   # B is written before P: wait for both
    Assert ((Field $f.B (U '1') 'title') -eq 'after-hook' -and (Field $f.P (U '1') 'title') -eq 'after-hook') 'late card update picked up by the follow-up'
    $deadline = (Get-Date).AddSeconds(15)
    while (@(Select-String -LiteralPath (Join-Path $f.Bk 'sync.log') -Pattern 'follow-up').Count -lt 2 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    Assert (@(Select-String -LiteralPath (Join-Path $f.Bk 'sync.log') -Pattern 'follow-up').Count -eq 2) 'two follow-up runs, then the helper exits'

    Write-Host "`n[17] a deleted session can be restored from the backup and stays"
    $f = New-Fixture
    Rec $f.A (U '1') 100 -Title 'keep-me' | Out-Null
    $r = SyncIt $f
    Remove-Item -LiteralPath (Join-Path $f.B "local_$(U '1').json"); Tomb $f.B (U '1') ((NowMs) + 1000)
    $r = SyncIt $f
    Assert (-not (Has $f.A (U '1'))) 'deleted everywhere'
    $r = Run (Join-Path $repo 'Restore-ClaudeSession.ps1') @{ Id = ('local_' + (U '1')); SessionRoots = $f.Roots; BackupRoot = $f.Bk }
    Assert ((Has $f.A (U '1')) -and (Has $f.B (U '1')) -and (Has $f.P (U '1'))) 'restored in every login'
    $r = SyncIt $f
    Assert ((Has $f.A (U '1')) -and (Field $f.P (U '1') 'title') -eq 'keep-me') 'still there after the next sync'

    Write-Host "`n[18] check: a login missing a card is a FAIL; failures from replaced link folders are history"
    $f = New-Fixture
    $p = Rec $f.A (U '1') 1
    (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddHours(-1)
    $c = CheckIt $f
    Assert ($c.Out -match 'FAIL  same list everywhere' -and $c.Code -eq 1) 'missing card reported as FAIL'
    $r = SyncIt $f
    $c = CheckIt $f
    Assert ($c.Out -match 'PASS  same list everywhere') 'PASS after sync'
    $log = Join-Path $f.Base 'main.log'
    $when = (Get-Date).AddMinutes(-30).ToString('yyyy-MM-dd HH:mm:ss')
    [IO.File]::WriteAllText($log, "$when [error] Failed to save session local_$(U '1'): Refusing non-directory at private dir path (symlink/file plant): $($f.B) { name: 'PlantDetectedError' }`r`n")
    (Get-Item -LiteralPath $f.B).CreationTime = (Get-Date).AddMinutes(-10)
    $c = CheckIt $f @{ DesktopLog = @($log) }
    Assert ($c.Out -match 'PASS  desktop saves  no new failures') 'failure from a folder replaced since then is history'
    (Get-Item -LiteralPath $f.B).CreationTime = (Get-Date).AddHours(-2)
    $c = CheckIt $f @{ DesktopLog = @($log) }
    Assert ($c.Out -match 'FAIL  desktop saves') 'failure on the current folder is a FAIL'

    Write-Host "`n[19] old backups are pruned: snapshots after 14 days, replaced copies after 3 days"
    $f = New-Fixture
    Rec $f.A (U '1') 1 | Out-Null
    $d20 = Join-Path $f.Bk ((Get-Date).AddDays(-20).ToString('yyyyMMdd')); $d5 = Join-Path $f.Bk ((Get-Date).AddDays(-5).ToString('yyyyMMdd')); $d1 = Join-Path $f.Bk ((Get-Date).AddDays(-1).ToString('yyyyMMdd'))
    foreach ($d in $d20, $d5, $d1) { New-Item -ItemType Directory -Path "$d\snapshot", "$d\replaced" -Force | Out-Null; [IO.File]::WriteAllText("$d\replaced\x.json", '{}') }
    $r = SyncIt $f
    Assert (-not (Test-Path -LiteralPath $d20)) '20-day-old backup removed'
    Assert ((Test-Path -LiteralPath "$d5\snapshot") -and -not (Test-Path -LiteralPath "$d5\replaced")) '5-day-old: snapshot kept, replaced copies removed'
    Assert (Test-Path -LiteralPath "$d1\replaced\x.json") 'yesterday kept in full'

    Write-Host "`n[20] installer: adds the hooks, keeps every other setting, is idempotent; uninstaller removes only ours"
    $f = New-Fixture
    $prof = Join-Path $f.Base 'profile'; New-Item -ItemType Directory -Path "$prof\.claude", "$prof\.cc-switch", "$prof\Desktop" -Force | Out-Null
    $sp = "$prof\.claude\settings.json"
    $zh = [string]([char]0x4E2D) + [char]0x6587
    $orig = '{"model":"opus","n":1.5,"big":1791601063931,"flag":false,"none":null,"empty":{},"list":[],"text":"' + $zh + ' \"q\" \\ tab\t","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"node other.mjs","timeout":10}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"x"}]}]},"statusLine":{"type":"command","command":"\"C:\\\\p\\\\node.exe\" a.mjs"}}'
    [IO.File]::WriteAllText($sp, $orig, $utf8)
    $py = Get-Command python -ErrorAction SilentlyContinue
    $dbOk = $false
    if ($py) {
        $mk = Join-Path $f.Base 'mkdb.py'
        [IO.File]::WriteAllText($mk, "import sqlite3,sys`ncon=sqlite3.connect(sys.argv[1])`ncon.execute('create table settings(key text primary key, value text)')`ncon.execute('create table providers(id text, app_type text, name text, meta text)')`ncon.execute(""insert into settings values('common_config_claude', '{\""model\"": \""opus\""}')"")`ncon.execute(""insert into providers values('1','claude','A','{\""commonConfigEnabled\"": true}')"")`ncon.execute(""insert into providers values('2','claude','B','{}')"")`ncon.commit()`n", $utf8)
        & $py.Source $mk "$prof\.cc-switch\cc-switch.db"; $dbOk = ($LASTEXITCODE -eq 0)
        $rd = Join-Path $f.Base 'readdb.py'   # a file, not python -c: PowerShell 5.1 mangles quotes in native arguments
        [IO.File]::WriteAllText($rd, "import sqlite3,sys`nprint(sqlite3.connect(sys.argv[1]).execute(""select value from settings where key='common_config_claude'"").fetchone()[0])`n", $utf8)
    }
    $oldProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = $prof
        $inst = Join-Path $f.Base 'installed'
        $out1 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'Install-SyncHook.ps1') -InstallDir $inst -SettingsPath $sp -NoShortcut -SkipSync 2>&1 | Out-String
        $after1 = [IO.File]::ReadAllText($sp)
        $out2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'Install-SyncHook.ps1') -InstallDir $inst -SettingsPath $sp -NoShortcut -SkipSync 2>&1 | Out-String
        $after2 = [IO.File]::ReadAllText($sp)
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $o = $ser.DeserializeObject($orig); $a = $ser.DeserializeObject($after1)
        Assert ($out1 -notmatch 'Exception' -and $after1 -eq $after2) 'install runs cleanly and a second install changes nothing'
        if ($out1 -match 'Exception' -or $after1 -ne $after2) { Write-Host $out1; Write-Host '--- after1'; Write-Host $after1; Write-Host '--- after2'; Write-Host $after2 }
        foreach ($k in 'model', 'n', 'big', 'flag', 'text', 'statusLine') { Assert (($ser.Serialize($a[$k])) -eq ($ser.Serialize($o[$k]))) "setting '$k' unchanged" }
        Assert ($a.ContainsKey('none') -and $a['none'] -eq $null -and $a['empty'].Count -eq 0 -and @($a['list']).Count -eq 0) 'null, {} and [] kept'
        Assert (@($a['hooks']['PreToolUse']).Count -eq 1 -and @($a['hooks']['SessionStart']).Count -eq 2) 'other hooks kept'
        foreach ($ev in 'Stop', 'StopFailure', 'SessionEnd') { Assert (([string]$a['hooks'][$ev][0]['hooks'][0]['command']) -match 'Sync-ClaudeSessions\.ps1" -Followup$') "$ev hook added with -Followup" }
        Assert ($a['hooks']['SessionStart'][1]['hooks'][0]['async'] -eq $true) 'SessionStart hook is async'
        Assert (Test-Path -LiteralPath (Join-Path $inst 'Sync-ClaudeSessions.ps1')) 'scripts installed'
        if ($dbOk) {
            $cc = (& $py.Source $rd "$prof\.cc-switch\cc-switch.db" | Out-String)
            Assert ($cc -match 'Sync-ClaudeSessions' -and $cc -match '"model"') 'CC Switch common config got the hooks and kept its other keys'
            Assert ($out1 -match "do not use the common config.*\bB\b") 'warns about a CC Switch provider without common config'
        } else { Write-Host '  (python missing: CC Switch part not exercised)' }
        $outU = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'Uninstall-SyncHook.ps1') -InstallDir $inst -SettingsPath $sp -KeepFiles 2>&1 | Out-String
        $u = $ser.DeserializeObject([IO.File]::ReadAllText($sp))
        Assert ($ser.Serialize($u) -eq $ser.Serialize($o)) 'uninstall restores the original settings exactly'
        if ($dbOk) {
            $cc = (& $py.Source $rd "$prof\.cc-switch\cc-switch.db" | Out-String)
            Assert ($cc -notmatch 'Sync-ClaudeSessions' -and $cc -match '"model"') 'uninstall removes the hooks from CC Switch only'
        }
    } finally { $env:USERPROFILE = $oldProfile }

    Write-Host "`n[12] check: failed desktop saves and conversations without a card"
    $f = New-Fixture
    Rec $f.A (U '1') 1 | Out-Null
    $log = Join-Path $f.Base 'main.log'
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [IO.File]::WriteAllText($log, "$now [error] Failed to save session local_$(U '1'): Refusing non-directory at private dir path (symlink/file plant): x`r`n")
    $proj = Join-Path $f.Base 'projects\C--proj'; New-Item -ItemType Directory -Path $proj -Force | Out-Null
    $orphan = '99999999-0000-4000-8000-000000000099'
    [IO.File]::WriteAllText((Join-Path $proj "$orphan.jsonl"), '{"type":"user","entrypoint":"claude-desktop"}' + "`n" + '{"type":"assistant","entrypoint":"claude-desktop"}' + "`n")
    [IO.File]::WriteAllText((Join-Path $proj "$(U '1').jsonl"), '{"type":"assistant","entrypoint":"claude-desktop"}' + "`n")
    $c = CheckIt $f @{ DesktopLog = $log; ProjectsDir = (Join-Path $f.Base 'projects') }
    Assert ($c.Out -match 'FAIL  desktop saves' -and $c.Code -eq 1) 'failed save reported as FAIL'
    Assert ($c.Out -match 'WARN  conversations without a card  1 ' -and $c.Out -match '99999999') 'conversation without a card reported'
    Tomb $f.A $orphan (NowMs)
    $c = CheckIt $f @{ DesktopLog = $log; ProjectsDir = (Join-Path $f.Base 'projects') }
    Assert ($c.Out -match 'PASS  conversations without a card') 'a conversation deleted on purpose is not reported'
    [IO.File]::WriteAllText($log, "2020-01-01 00:00:00 [error] Failed to save session local_$(U '1'): old`r`n")
    $c = CheckIt $f @{ DesktopLog = $log }
    Assert ($c.Out -match 'PASS  desktop saves') 'old failures outside the window are ignored'

    Write-Host "`n[13] check reports settings that 'claude doctor' says are invalid"
    $badStub = Join-Path $f.Base 'claude-bad.cmd'; $okStub = Join-Path $f.Base 'claude-ok.cmd'
    [IO.File]::WriteAllText($badStub, "@echo off`r`necho Claude Code doctor`r`necho Invalid settings`r`necho - settings.json: attribution.commit: Expected string, but received undefined`r`necho Multiple installations found`r`n")
    [IO.File]::WriteAllText($okStub, "@echo off`r`necho Claude Code doctor`r`necho Running: native`r`n")
    $c = CheckIt $f @{ SkipDoctor = $false; ClaudeCommand = $badStub }
    Assert ($c.Out -match 'FAIL  settings valid .*attribution\.commit' -and $c.Code -eq 1) 'invalid settings reported as FAIL'
    $c = CheckIt $f @{ SkipDoctor = $false; ClaudeCommand = $okStub }
    Assert ($c.Out -match 'PASS  settings valid') 'valid settings reported as PASS'
}
catch { $script:failed++; Write-Host "ERROR: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red }
finally {
    foreach ($d in $script:dirs) {
        Get-ChildItem -LiteralPath $d -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | ForEach-Object { [IO.Directory]::Delete($_.FullName, $false) }
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
