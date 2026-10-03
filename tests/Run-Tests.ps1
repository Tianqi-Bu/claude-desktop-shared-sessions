# Self-contained tests: build fake Claude session folders under %TEMP%, run the scripts
# against them via -SessionRoots, and assert the results. Never touches real Claude data.
#   powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$link = Join-Path $repo 'Link-ClaudeAccounts.ps1'
$unlink = Join-Path $repo 'Unlink-ClaudeAccounts.ps1'
$check = Join-Path $repo 'Check-ClaudeSwitch.ps1'
$utf8 = New-Object Text.UTF8Encoding $false

$script:passed = 0; $script:failed = 0; $script:dirs = @()
function Assert($cond, $msg) {
    if ($cond) { $script:passed++; Write-Host "  ok    $msg" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  FAIL  $msg" -ForegroundColor Red }
}
# run a script in-process, capture every output stream and its exit code
function Run([string]$script, [hashtable]$params) {
    $global:LASTEXITCODE = 0
    $out = try { & $script @params *>&1 | Out-String -Width 4096 } catch { "THROWN: " + $_.Exception.Message }
    return @{ Out = $out; Code = $global:LASTEXITCODE }
}
function U([string]$c) { "$c$c$c$c$c$c$c$c-0000-4000-8000-00000000000$c" }   # readable fake UUIDs
function Rec($dir, $id, $activity, [switch]$Damaged, [switch]$Bom, $Title = 't') {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $link = if ($Damaged) { '"transcriptUnavailable":true' } else { '"cliSessionId":"' + $id + '"' }
    $json = '{"sessionId":"local_' + $id + '",' + $link + ',"title":"' + $Title + '","lastActivityAt":' + $activity + '}'
    $enc = if ($Bom) { New-Object Text.UTF8Encoding $true } else { $utf8 }
    [IO.File]::WriteAllText((Join-Path $dir "local_$id.json"), $json, $enc)
}
function Field($dir, $id, $name) {
    $t = [IO.File]::ReadAllText((Join-Path $dir "local_$id.json"))
    [regex]::Match($t, '"' + $name + '":"?([^",}]*)').Groups[1].Value
}
function Names($dir) { @(Get-ChildItem -LiteralPath $dir -Filter 'local_*.json' -Force | ForEach-Object Name | Sort-Object) }
function IsLink($p) { $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; [bool]($i -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) }
function Snapshot($dir) { (Get-ChildItem -LiteralPath $dir -Recurse -Force | ForEach-Object { $_.FullName + '|' + $(if ($_.PSIsContainer) { 'd' } else { $_.Length }) }) -join "`n" }
# a fresh fake machine: official root r1 (master A) and third-party root r2 (P)
function New-Fixture([string]$tag = '') {
    $b = Join-Path $env:TEMP ("cslink-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + $tag)
    $script:dirs += $b
    $f = @{ Base = $b; R1 = (Join-Path $b 'official\claude-code-sessions'); R2 = (Join-Path $b 'thirdparty\claude-code-sessions') }
    $f.A = Join-Path $f.R1 ((U 'a') + '\' + (U 'b'))
    $f.P = Join-Path $f.R2 ((U 'c') + '\' + (U 'd'))
    $f.Roots = @($f.R1, $f.R2)
    $f.Bk = Join-Path $b 'backup'
    return $f
}

try {
    Write-Host "`n[1] dry run plans the merge and changes nothing"
    $f = New-Fixture
    Rec $f.A (U '1') 100; Rec $f.A (U '2') 100; Rec $f.A (U '5') 100; Rec $f.A (U '6') 100
    [IO.File]::WriteAllText((Join-Path $f.A ('deleted_' + (U '3'))), '1')
    Rec $f.P (U '2') 999; Rec $f.P (U '3') 100; Rec $f.P (U '4') 100
    [IO.File]::WriteAllText((Join-Path $f.P 'scheduled-tasks.json'), '{"scheduledTasks":[{"taskId":"x"}]}')
    New-Item -ItemType Directory -Path (Join-Path $f.P 'backlog') | Out-Null
    $snap = Snapshot $f.Base
    $r = Run $link @{ SessionRoots = $f.Roots }
    Assert ($r.Code -eq 0) 'exit code 0'
    Assert ($r.Out -match 'add 1, update 1, skip 1 deleted in master') 'plans add 1 / update 1 / skip 1'
    Assert ($r.Out -match 'scheduled tasks') 'warns about scheduled tasks'
    Assert ($r.Out -match 'not merged, kept in the backup: .*backlog') 'lists other items it will not merge'
    Assert ((Snapshot $f.Base) -eq $snap) 'no file touched'

    Write-Host "`n[2] apply merges, links, and keeps backups"
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk }
    Assert ($r.Code -eq 0) 'exit code 0'
    Assert (IsLink $f.P) 'third-party folder is now a link'
    Assert ((Names $f.P).Count -eq 5) 'third-party view shows 5 sessions'
    Assert (-not ((Names $f.A) -contains ('local_' + (U '3') + '.json'))) 'session deleted in master stays deleted'
    Assert ((Field $f.A (U '2') 'lastActivityAt') -eq '999') 'newer copy won'
    Assert ((Field (Join-Path $f.Bk 'master-before') (U '2') 'lastActivityAt') -eq '100') 'master original kept in backup'
    Assert (Test-Path -LiteralPath (Join-Path $f.Bk (((U 'c') + '__' + (U 'd')) + '\backlog'))) 'replaced folder kept whole in backup'

    Write-Host "`n[3] check passes; rerun is a no-op"
    $r = Run $check @{ SessionRoots = $f.Roots }
    Assert ($r.Out -match 'PASS  one shared list' -and $r.Out -match 'PASS  link') 'check passes'
    $snap = Snapshot $f.A
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = (Join-Path $f.Base 'bk2') }
    Assert ($r.Out -match 'already linked' -and $r.Out -match 'Nothing to do' -and $r.Code -eq 0) 'nothing to do'
    Assert ((Snapshot $f.A) -eq $snap -and -not (Test-Path (Join-Path $f.Base 'bk2'))) 'no change, no backup'

    Write-Host "`n[4] a new login appears and gets linked"
    $N = Join-Path $f.R2 ((U 'e') + '\' + (U 'f'))
    Rec $N (U '7') 100
    $r = Run $check @{ SessionRoots = $f.Roots }
    Assert ($r.Out -match 'FAIL  one shared list' -and $r.Code -eq 1) 'check flags the separate list'
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = (Join-Path $f.Base 'bk3') }
    Assert ((IsLink $N) -and (Names $N).Count -eq 6) 'new login linked and sees all 6'

    Write-Host "`n[5] unlink gives each login a full copy, master untouched"
    [IO.File]::WriteAllText((Join-Path $f.A 'scheduled-tasks.json'), '{"scheduledTasks":[]}')
    $snap = Snapshot $f.A
    $r = Run $unlink @{ SessionRoots = $f.Roots; Apply = $true }
    Assert (-not (IsLink $f.P) -and -not (IsLink $N)) 'no links left'
    Assert ((Names $f.P).Count -eq 6 -and (Test-Path -LiteralPath (Join-Path $f.P 'scheduled-tasks.json'))) 'copy includes records and other files'
    Assert ((Snapshot $f.A) -eq $snap) 'master untouched'
    Assert (-not (Test-Path -LiteralPath (Join-Path $f.P '.claude-session-link-master'))) 'master marker not copied by unlink'
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = (Join-Path $f.Base 'bk4') }
    Assert ((IsLink $f.P) -and -not (IsLink $f.A)) 'relink after unlink keeps the official folder as master'
    Assert ($r.Out -notmatch 'scheduled tasks' -and $r.Out -notmatch 'differs from the master') 'relink does not flag files identical to the master'

    Write-Host "`n[6] refuses to apply while a profile is running"
    $f = New-Fixture
    Rec $f.A (U '1') 100; Rec $f.P (U '2') 100
    $lock = Join-Path $f.Base 'thirdparty\lockfile'
    $fs = [IO.File]::Open($lock, 'Create', 'ReadWrite', 'None')
    try {
        $snap = Snapshot $f.Base
        $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk }
        Assert ($r.Out -match 'Claude Desktop is running') 'link refuses'
        $r2 = Run $unlink @{ SessionRoots = $f.Roots; Apply = $true }
        Assert ($r2.Out -match 'Claude Desktop is running') 'unlink refuses'
        Assert ((Snapshot $f.Base) -eq $snap) 'nothing changed'
        $r = Run $link @{ SessionRoots = $f.Roots }
        Assert ($r.Code -eq 0 -and $r.Out -match 'Dry run') 'dry run still allowed'
    } finally { $fs.Close() }

    Write-Host "`n[7] a locked folder fails safely"
    $f = New-Fixture
    Rec $f.A (U '1') 100; Rec $f.A (U '5') 100; Rec $f.P (U '2') 100
    $h = [IO.File]::Open((Join-Path $f.P ('local_' + (U '2') + '.json')), 'Open', 'Read', 'None')
    try { $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk } } finally { $h.Close() }
    Assert ($r.Code -eq 1 -and $r.Out -match 'FAILED') 'reports failure, exit 1'
    Assert ((Test-Path -LiteralPath $f.P) -and -not (IsLink $f.P) -and (Names $f.P).Count -eq 1) 'folder left in place with its record'
    Assert (-not (Test-Path -LiteralPath (Join-Path $f.A '.claude-session-link-master'))) 'no master marker when nothing got linked'
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = (Join-Path $f.Base 'bk2') }
    Assert (IsLink $f.P) 'linked once the lock is gone'
    Assert (Test-Path -LiteralPath (Join-Path $f.A '.claude-session-link-master')) 'master marked after a successful link'

    Write-Host "`n[7b] an unreadable non-record item does not abort the run"
    $f = New-Fixture
    Rec $f.A (U '1') 1; Rec $f.A (U '5') 1; Rec $f.P (U '2') 1
    New-Item -ItemType Directory -Path (Join-Path $f.A 'backlog'), (Join-Path $f.P 'backlog') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $f.A 'backlog\tasks.json'), '{"a":1}'); [IO.File]::WriteAllText((Join-Path $f.P 'backlog\tasks.json'), '{"a":1}')
    $h = [IO.File]::Open((Join-Path $f.P 'backlog\tasks.json'), 'Open', 'Read', 'None')
    try { $r = Run $link @{ SessionRoots = $f.Roots } } finally { $h.Close() }
    Assert ($r.Code -eq 0 -and $r.Out -match 'differs from the master.*backlog') 'dry run finishes and lists the unreadable item'

    Write-Host "`n[8] healthy beats damaged, whatever the times"
    $f = New-Fixture
    Rec $f.A (U '1') 5000 -Damaged; Rec $f.A (U '5') 10; Rec $f.A (U '6') 10
    Rec $f.P (U '1') 10; Rec $f.P (U '5') 5000 -Damaged
    $r = Run $check @{ SessionRoots = $f.Roots }
    Assert ($r.Out -match 'WARN  unlinked records  2 session') 'check counts damaged records'
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk }
    Assert ((Field $f.A (U '1') 'cliSessionId') -ne '') 'healthy older copy replaced the damaged one'
    Assert ((Field $f.A (U '5') 'cliSessionId') -ne '') 'damaged newer copy did not replace the healthy one'

    Write-Host "`n[9] a BOM record never spreads"
    $f = New-Fixture
    Rec $f.A (U '1') 100; Rec $f.A (U '5') 100
    Rec $f.P (U '1') 999 -Bom; Rec $f.P (U '2') 100 -Bom
    $r = Run $check @{ SessionRoots = $f.Roots }
    Assert ($r.Out -match 'WARN  unreadable records  2 session') 'check reports BOM records'
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk }
    Assert ($r.Out -match '2 record\(s\) here are unreadable') 'warns about them'
    $bytes = [IO.File]::ReadAllBytes((Join-Path $f.A ('local_' + (U '1') + '.json')))
    Assert ($bytes[0] -eq 0x7B) 'master copy not replaced by the BOM copy'
    Assert (-not (Test-Path -LiteralPath (Join-Path $f.A ('local_' + (U '2') + '.json')))) 'BOM-only record not copied'

    Write-Host "`n[9b] a truncated record never wins"
    $f = New-Fixture
    Rec $f.A (U '1') 100 -Title 'GOOD'; Rec $f.A (U '5') 1
    New-Item -ItemType Directory -Path $f.P -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $f.P ('local_' + (U '1') + '.json')), ('{"sessionId":"local_' + (U '1') + '","cliSessionId":"' + (U '1') + '","lastActivityAt":999,"title":"TRUNC'), $utf8)
    $r = Run $check @{ SessionRoots = $f.Roots }
    Assert ($r.Out -match 'WARN  unreadable records  1 session') 'check reports the truncated record'
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk }
    Assert ((Field $f.A (U '1') 'title') -eq 'GOOD') 'truncated newer copy did not replace the good one'

    Write-Host "`n[10] the master's original survives several updates in one run"
    $f = New-Fixture
    Rec $f.A (U '1') 100 -Title 'ORIGINAL'; Rec $f.A (U '5') 1; Rec $f.A (U '6') 1
    Rec $f.P (U '1') 200 -Title 'F1'
    $Q = Join-Path $f.R2 ((U 'e') + '\' + (U 'f')); Rec $Q (U '1') 300 -Title 'F2'
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk }
    Assert ((Field $f.A (U '1') 'title') -eq 'F2') 'newest copy ends up in the master'
    Assert ((Field (Join-Path $f.Bk 'master-before') (U '1') 'title') -eq 'ORIGINAL') 'backup still holds the original'

    Write-Host "`n[11] same lastActivityAt: the more recently written copy wins"
    $f = New-Fixture
    Rec $f.A (U '1') 100 -Title 'old'; Rec $f.A (U '5') 1
    Rec $f.P (U '1') 100 -Title 'renamed'
    (Get-Item -LiteralPath (Join-Path $f.A ('local_' + (U '1') + '.json'))).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2)
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk }
    Assert ((Field $f.A (U '1') 'title') -eq 'renamed') 'rename made in the other login kept'

    Write-Host "`n[12] equal sizes: the official (first) root is the master"
    $f = New-Fixture
    Rec $f.A (U '1') 1; Rec $f.P (U '2') 1
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk }
    Assert ((IsLink $f.P) -and -not (IsLink $f.A)) 'official folder kept as master'

    Write-Host "`n[13] a root that is itself a link is refused"
    $f = New-Fixture
    Rec $f.A (U '1') 1
    New-Item -ItemType Directory -Path (Split-Path $f.R2 -Parent) -Force | Out-Null
    New-Item -ItemType Junction -Path $f.R2 -Target $f.R1 | Out-Null
    $snap = Snapshot $f.R1
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk }
    Assert ($r.Out -match 'is itself a link') 'refused with a clear message'
    Assert ((Snapshot $f.R1) -eq $snap -and -not (Test-Path $f.Bk)) 'master untouched, nothing moved'

    Write-Host "`n[14] paths with spaces, brackets and non-ASCII characters"
    $f = New-Fixture (' ' + [char]0x5F20 + [char]0x4E09 + ' [Work] (x)')   # Chinese name built from code points keeps this file ASCII
    Rec $f.A (U '1') 1; Rec $f.A (U '5') 1; Rec $f.P (U '2') 1
    [IO.File]::WriteAllText((Join-Path $f.P 'scheduled-tasks.json'), '{"scheduledTasks":[{"taskId":"x"}]}')
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk }
    Assert ($r.Code -eq 0 -and (IsLink $f.P)) 'linked'
    Assert ($r.Out -match 'scheduled tasks') 'scheduled tasks still detected'
    Assert ((Names $f.P).Count -eq 3) 'link resolves to the master'
    $r = Run $unlink @{ SessionRoots = $f.Roots; Apply = $true }
    Assert (-not (IsLink $f.P) -and (Names $f.P).Count -eq 3) 'unlink works too'

    Write-Host "`n[16] the marked master stays master after unlink + relink (several official accounts)"
    $f = New-Fixture
    $M1 = Join-Path $f.R1 ((U 'f') + '\' + (U 'f'))   # sorts last by path, but has the most sessions
    $M2 = Join-Path $f.R1 ((U '0') + '\' + (U '0'))
    Rec $M1 (U '1') 1; Rec $M1 (U '5') 1; Rec $M1 (U '6') 1; Rec $M2 (U '2') 1
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk }
    Assert ((IsLink $M2) -and -not (IsLink $M1)) 'biggest official folder became master'
    $r = Run $unlink @{ SessionRoots = $f.Roots; Apply = $true }
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = (Join-Path $f.Base 'bk2') }
    Assert ((IsLink $M2) -and -not (IsLink $M1)) 'same master after unlink + relink (equal sizes)'

    Write-Host "`n[17] a missing shared list is reported, and unlink leaves links alone"
    $f = New-Fixture
    Rec $f.A (U '1') 1; Rec $f.A (U '5') 1; Rec $f.P (U '2') 1
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $f.Bk }
    Rename-Item -LiteralPath $f.A -NewName 'gone'
    $r = Run $check @{ SessionRoots = $f.Roots }
    Assert ($r.Out -match 'FAIL  shared list missing' -and $r.Code -eq 1) 'check reports the missing list'
    $r = Run $unlink @{ SessionRoots = $f.Roots; Apply = $true }
    Assert ($r.Code -eq 1 -and (IsLink $f.P)) 'unlink refuses to replace a link whose list is gone'
    Assert ($r.Out -match 'AllowEmpty') 'and points at the way out'
    $r = Run $link @{ SessionRoots = $f.Roots }
    Assert ($r.Out -match 'shared list is missing' -and $r.Out -notmatch 'run Unlink-ClaudeAccounts.ps1\.') 'link explains the missing list consistently'
    Rename-Item -LiteralPath (Join-Path (Split-Path $f.A -Parent) 'gone') -NewName (Split-Path $f.A -Leaf)

    Write-Host "`n[17b] -AllowEmpty turns a broken link into an empty folder"
    $g = New-Fixture
    Rec $g.A (U '1') 1; Rec $g.A (U '5') 1; Rec $g.P (U '2') 1
    $r = Run $link @{ SessionRoots = $g.Roots; Apply = $true; BackupDir = $g.Bk }
    Rename-Item -LiteralPath $g.A -NewName 'gone'
    $r = Run $unlink @{ SessionRoots = $g.Roots; Apply = $true; AllowEmpty = $true }
    Assert ($r.Code -eq 0 -and -not (IsLink $g.P) -and (Test-Path -LiteralPath $g.P) -and (Names $g.P).Count -eq 0) 'broken link replaced by an empty folder'

    Write-Host "`n[18] a failed unlink copy leaves the link in place"
    $h = [IO.File]::Open((Join-Path $f.A ('local_' + (U '5') + '.json')), 'Open', 'Read', 'None')
    try { $r = Run $unlink @{ SessionRoots = $f.Roots; Apply = $true } } finally { $h.Close() }
    Assert ($r.Code -eq 1 -and (IsLink $f.P)) 'link kept'
    Assert (-not (Test-Path -LiteralPath ($f.P + '.cslink-unlink'))) 'no staging folder left behind'

    Write-Host "`n[15] a backup folder on another drive is refused"
    $f = New-Fixture
    Rec $f.A (U '1') 1; Rec $f.A (U '5') 1; Rec $f.P (U '2') 1
    $unc = '\\localhost\' + $env:SystemDrive.TrimEnd(':') + '$' + $f.Base.Substring(2) + '\bk-unc'
    $r = Run $link @{ SessionRoots = $f.Roots; Apply = $true; BackupDir = $unc }
    Assert ($r.Code -eq 1 -and $r.Out -match 'on another drive') 'refused'
    Assert (-not (IsLink $f.P) -and (Names $f.P).Count -eq 1) 'folder untouched'
}
catch { $script:failed++; Write-Host "ERROR: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red }
finally {
    foreach ($d in $script:dirs) {
        # remove links first so recursive cleanup never walks into a target
        Get-ChildItem -LiteralPath $d -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | ForEach-Object { [IO.Directory]::Delete($_.FullName, $false) }
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
