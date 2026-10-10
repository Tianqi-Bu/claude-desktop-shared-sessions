# Migration from the old junction version of this project: turn every account/org folder
# that is a link (official and third-party profile) back into a real folder holding a full
# COPY of the list it pointed at (records, tombstones, scheduled tasks, everything).
# Claude Desktop refuses to save session cards into a link, so links must go.
# Install-SyncHook.ps1 runs this automatically. The folder that was linked to is not changed.
#
# Quit Claude Desktop completely (tray icon -> Quit) before running with -Apply.
#   powershell -ExecutionPolicy Bypass -File .\Unlink-ClaudeAccounts.ps1          # dry run, changes nothing
#   powershell -ExecutionPolicy Bypass -File .\Unlink-ClaudeAccounts.ps1 -Apply
#   ... -Apply -AllowEmpty   # if the shared list itself is gone: turn broken links into empty folders

param(
    [switch]$Apply,
    [switch]$AllowEmpty,      # replace links whose shared list is gone with empty folders
    [string[]]$SessionRoots   # optional: override root discovery (used by the tests)
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$custom = $PSBoundParameters.ContainsKey('SessionRoots')
$roots = Resolve-SessionRoots $(if ($custom) { $SessionRoots } else { Get-DefaultSessionRoots })
if ($Apply -and (Test-DesktopRunning $roots (-not $custom))) {
    throw "Claude Desktop is running. Quit it completely (tray icon -> Quit), then run this again."
}

$n = 0; $errors = 0
$leaves = Get-Leaves $roots
foreach ($l in @($leaves | Where-Object { $_.IsLink })) {
    $n++
    $gone = -not (Test-Path -LiteralPath $l.Target)
    Write-Host ("UNLINK  {0}  (was -> {1}{2})" -f $l.Path, $l.Target, $(if ($gone) { ', which is gone' } else { '' }))
    if (-not $Apply) { continue }

    if ($gone -and -not $AllowEmpty) {
        Write-Warning "        the shared list is missing; link left as is. $script:MissingListHelp"
        $errors++; continue
    }
    # build the replacement in a sibling staging folder first, so a failure leaves the link untouched
    $stage = $l.Path + '.cslink-unlink'
    try {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        New-Item -ItemType Directory -Path $stage | Out-Null
        if (-not $gone) {
            Get-ChildItem -LiteralPath $l.Target -Force | Where-Object { $_.Name -ne $script:MasterMarker -and $_.Name -notlike '.cslink-probe-*' } |
                ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $stage -Recurse -Force }
        }
    } catch {
        Write-Warning "FAILED  copying the list for $($l.Path): $($_.Exception.Message). Link left as is."
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        $errors++; continue
    }
    # swap: remove the link (never the files it points to), move the staged copy in;
    # if the move fails, put the link back so the login keeps working
    try {
        [IO.Directory]::Delete($l.Path, $false)
        Move-Item -LiteralPath $stage -Destination $l.Path
        Write-Host $(if ($gone) { "        now an empty real folder" } else { "        now a real folder with a full copy of the list" })
    } catch {
        Write-Warning "FAILED  swapping $($l.Path): $($_.Exception.Message)"
        if (-not (Test-Path -LiteralPath $l.Path) -and -not $gone) {
            try {
                $tgt = if ($PSVersionTable.PSVersion.Major -lt 6) { [WildcardPattern]::Escape($l.Target) } else { $l.Target }
                New-Item -ItemType Junction -Path $l.Path -Target $tgt | Out-Null
                Write-Warning "        the link was restored; the staged copy is at $stage"
            } catch {
                Write-Warning "        could not restore the link either. The copy is at $stage; rename it to $($l.Path) by hand."
            }
        }
        $errors++
    }
}
if ($n -eq 0) { Write-Host "No linked folders found." }
elseif (-not $Apply) { Write-Host "`nDry run only. Quit Claude Desktop, then re-run with -Apply." }
if ($errors -gt 0) { exit 1 }
