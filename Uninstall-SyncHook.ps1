# Remove the Claude Desktop session-list sync: its hooks (settings.json and CC Switch's
# common config), the desktop shortcut and the installed scripts. Your other hooks, every
# session card and the backups in %USERPROFILE%\claude-session-sync-backup are kept.
#   powershell -ExecutionPolicy Bypass -File .\Uninstall-SyncHook.ps1
# Each login keeps the cards it has now; they just stop being kept in step.

param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.claude-session-sync'),
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [switch]$SkipCCSwitch,
    [switch]$KeepFiles         # used by the tests
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hooks.ps1')
$backupDir = Join-Path $env:USERPROFILE 'claude-session-sync-backup\install'

if (Test-Path -LiteralPath $SettingsPath) {
    $settings = Read-JsonFile $SettingsPath
    Remove-SyncHooks $settings
    Write-JsonFile $SettingsPath $settings $backupDir
    Write-Host "Removed the sync hooks from $SettingsPath (backup in $backupDir)"
}
if (-not $SkipCCSwitch) { Write-Host (Update-CCSwitchHooks 'remove' $SettingsPath $backupDir) }

if (-not $KeepFiles) {
    $ws = New-Object -ComObject WScript.Shell
    foreach ($l in @(Get-ChildItem ([Environment]::GetFolderPath('Desktop')) -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
        if ($ws.CreateShortcut($l.FullName).Arguments -match [regex]::Escape((Join-Path $InstallDir 'Sync-Now.ps1'))) { Remove-Item -LiteralPath $l.FullName -Force; Write-Host "Removed shortcut $($l.Name)" }
    }
    $here = (Resolve-Path -LiteralPath $PSScriptRoot).Path
    if ((Test-Path -LiteralPath $InstallDir) -and $here -ne (Resolve-Path -LiteralPath $InstallDir).Path) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force; Write-Host "Removed $InstallDir"
    } elseif (Test-Path -LiteralPath $InstallDir) {
        Write-Host "Delete $InstallDir yourself (this script is running from it)."
    }
}
Write-Host "Uninstalled."
