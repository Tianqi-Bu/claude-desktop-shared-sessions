# 接入新账号 / Connect a new login: guided, double-click friendly wrapper around
# Link-ClaudeAccounts.ps1. Saved as UTF-8 with BOM so Windows PowerShell 5.1 shows the Chinese text.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$link  = Join-Path $PSScriptRoot 'Link-ClaudeAccounts.ps1'
$check = Join-Path $PSScriptRoot 'Check-ClaudeSwitch.ps1'
function Step($text) { Write-Host "`n$text" -ForegroundColor Cyan }
function Run-Child([string]$script, [string[]]$extra) {
    # show the child's output on screen; return only its exit code
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @extra | Out-Host
    return [int]$LASTEXITCODE
}

Write-Host "==== 接入新账号：让这个登录也使用共享的会话列表 ====" -ForegroundColor White
Write-Host "前提：新账号（或新的第三方配置）已经登录过一次，并打开过 Code 标签。"

try {
    $roots = Resolve-SessionRoots (Get-DefaultSessionRoots)
} catch {
    Write-Host "`n出错了：$($_.Exception.Message)" -ForegroundColor Red
    Read-Host "按回车关闭窗口"; return
}
while (Test-DesktopRunning $roots $true) {
    Write-Host "`nClaude 桌面端还在运行。请在任务栏右下角的托盘图标上右键，选择 Quit（退出）。" -ForegroundColor Yellow
    Read-Host "退出后按回车继续"
}

Step "第 1 步：预览（不会改动任何东西）"
$preview = Run-Child $link @()
if ($preview -ne 0) {
    Write-Host "`n预览这一步就出错了（见上方信息），为安全起见不继续。可以截图这个窗口求助。" -ForegroundColor Red
    Read-Host "按回车关闭窗口"; return
}

Step "第 2 步：确认"
$answer = Read-Host "按回车开始接入；输入 n 再回车取消"
if ($answer -match '^\s*[nN]') { Write-Host "已取消，没有做任何改动。"; Read-Host "按回车关闭窗口"; return }

Step "第 3 步：接入"
$code = Run-Child $link @('-Apply')

Step "第 4 步：体检"
Run-Child $check @() | Out-Null

if ($code -eq 0) { Write-Host "`n完成。现在可以重新打开 Claude，切到这个账号就能看到所有对话。" -ForegroundColor Green }
else { Write-Host "`n有步骤失败（见上方 FAILED 行）。失败的那个登录没有被换成链接，原目录还在；已经合并进主列表的会话会留在主列表里。可以截图这个窗口求助。" -ForegroundColor Red }
Read-Host "按回车关闭窗口"
