# 立即同步 Claude 会话列表并体检 / Sync the Claude session list now and run the health check.
# Double-click target of the desktop shortcut. Saved as UTF-8 with BOM so Windows PowerShell 5.1
# shows the Chinese text correctly.

$here = $PSScriptRoot
Write-Host "==== 同步 Claude 会话列表 / Syncing the Claude session list ====" -ForegroundColor White
Write-Host "把所有账号（包括第三方模式）的会话卡片合并成同一份。对话内容本身不会被读写。"
Write-Host "Merges the session cards of every login (including third-party mode). Conversations themselves are not touched.`n"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Sync-ClaudeSessions.ps1') -Verbose2 | Out-Host
Write-Host "`n==== 体检 / Health check ====" -ForegroundColor White
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Check-ClaudeSwitch.ps1') | Out-Host
Write-Host "`nClaude 正在使用的那个账号，要切换一次账号或重启 Claude 后，列表里才会显示新同步过来的会话。" -ForegroundColor Cyan
Write-Host "The login Claude has open shows newly synced sessions after one account switch or a Claude restart." -ForegroundColor Cyan
Read-Host "按回车关闭 / Press Enter to close"
