# Install the Claude Desktop session-list sync on this PC.
#   powershell -ExecutionPolicy Bypass -File .\Install-SyncHook.ps1
# Quit Claude Desktop first if you used the old junction version (it is converted to real folders).
#
# What it does:
#   1. copies the scripts to %USERPROFILE%\.claude-session-sync\
#   2. turns any account/org folder that is a link (old junction version) into a real folder
#   3. adds the sync hooks to %USERPROFILE%\.claude\settings.json (your other hooks stay; a backup is kept)
#   4. if CC Switch is installed, puts the same hooks into its Claude common config
#   5. runs one sync and the health check, and adds a desktop shortcut
# Undo everything with Uninstall-SyncHook.ps1.

param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.claude-session-sync'),
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [switch]$NoShortcut,
    [switch]$SkipCCSwitch,
    [switch]$SkipSync          # used by the tests
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
. (Join-Path $src 'common.ps1')
. (Join-Path $src 'hooks.ps1')
$backupDir = Join-Path $env:USERPROFILE 'claude-session-sync-backup\install'

Write-Host "1. Copying scripts to $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
foreach ($f in 'common.ps1', 'hooks.ps1', 'Sync-ClaudeSessions.ps1', 'Check-ClaudeSwitch.ps1', 'Restore-ClaudeSession.ps1', 'Unlink-ClaudeAccounts.ps1', 'Sync-Now.ps1', 'Uninstall-SyncHook.ps1') {
    if ((Resolve-Path -LiteralPath $src).Path -ne (Resolve-Path -LiteralPath $InstallDir).Path) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination $InstallDir -Force }
}

if (-not $SkipSync) {
    $roots = Resolve-SessionRoots (Get-DefaultSessionRoots)
    $links = @((Get-Leaves $roots) | Where-Object { $_.IsLink })
    if ($links.Count -gt 0) {
        Write-Host "2. $($links.Count) link folder(s) from the old junction version: Claude Desktop cannot save into them"
        if (Test-DesktopRunning $roots $true) { throw "Quit Claude Desktop completely (tray icon -> Quit) and run the installer again, so these folders can be turned into real folders." }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'Unlink-ClaudeAccounts.ps1') -Apply | Out-Host
    } else { Write-Host "2. No link folders" }
}

Write-Host "3. Adding hooks to $SettingsPath"
New-Item -ItemType Directory -Path (Split-Path -Parent $SettingsPath) -Force | Out-Null
$settings = Read-JsonFile $SettingsPath
Add-SyncHooks $settings (Join-Path $InstallDir 'Sync-ClaudeSessions.ps1')
Write-JsonFile $SettingsPath $settings $backupDir
Write-Host "   done (previous file backed up in $backupDir)"

if ($SkipCCSwitch) { Write-Host "4. CC Switch: skipped" }
else { Write-Host ("4. " + (Update-CCSwitchHooks 'install' $SettingsPath $backupDir)) }

if (-not $NoShortcut) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Sync Claude Sessions.lnk'
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $InstallDir 'Sync-Now.ps1') + '"'
    $s.WorkingDirectory = $InstallDir
    $s.IconLocation = "$env:SystemRoot\System32\shell32.dll,238"
    $s.Description = 'Sync the Claude Desktop session list across all logins, then run the health check'
    $s.Save()
    Write-Host "5. Desktop shortcut: $lnk"
}

if (-not $SkipSync) {
    Write-Host "`nFirst sync:"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'Sync-ClaudeSessions.ps1') -Verbose2 | Select-Object -Last 1 | Out-Host
    Write-Host "`nHealth check:"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'Check-ClaudeSwitch.ps1') | Out-Host
}
Write-Host "`nInstalled. From now on every login sees the same session list. Switch accounts after Claude finishes a reply."
