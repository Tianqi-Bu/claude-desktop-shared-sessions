# Helpers for Install-SyncHook.ps1 / Uninstall-SyncHook.ps1: edit the "hooks" block of
# Claude Code's settings.json and (optionally) CC Switch's shared "common config".
# Windows PowerShell 5.1 only needs .NET Framework: JSON is parsed with JavaScriptSerializer
# and written back by a small pretty-printer that keeps key order and Unicode text as is.

Add-Type -AssemblyName System.Web.Extensions
$script:Ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:Ser.MaxJsonLength = [int]::MaxValue
$script:Ser.RecursionLimit = 1000
$script:Marker = 'Sync-ClaudeSessions.ps1'   # how our hook entries are recognised

function ConvertTo-PrettyJson($v, [int]$level = 0) {
    $pad = '  ' * ($level + 1); $end = '  ' * $level
    if ($v -eq $null) { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [string]) {
        $sb = New-Object Text.StringBuilder; [void]$sb.Append('"')
        foreach ($ch in $v.ToCharArray()) {
            switch ($ch) {
                '"' { [void]$sb.Append('\"') } '\' { [void]$sb.Append('\\') }
                "`n" { [void]$sb.Append('\n') } "`r" { [void]$sb.Append('\r') } "`t" { [void]$sb.Append('\t') }
                "`b" { [void]$sb.Append('\b') } "`f" { [void]$sb.Append('\f') }
                default { if ([int]$ch -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) } else { [void]$sb.Append($ch) } }
            }
        }
        [void]$sb.Append('"'); return $sb.ToString()
    }
    if ($v -is [System.Collections.IDictionary]) {
        if ($v.Count -eq 0) { return '{}' }
        $parts = foreach ($k in $v.Keys) { $pad + (ConvertTo-PrettyJson ([string]$k) 0) + ': ' + (ConvertTo-PrettyJson $v[$k] ($level + 1)) }
        return "{`n" + ($parts -join ",`n") + "`n$end}"
    }
    if ($v -is [System.Collections.IEnumerable]) {
        $items = @($v)
        if ($items.Count -eq 0) { return '[]' }
        $parts = foreach ($i in $items) { $pad + (ConvertTo-PrettyJson $i ($level + 1)) }
        return "[`n" + ($parts -join ",`n") + "`n$end]"
    }
    if ($v -is [decimal] -or $v -is [double] -or $v -is [single]) { return ([decimal]$v).ToString([Globalization.CultureInfo]::InvariantCulture) }
    return ([string]$v)
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return (New-Object 'System.Collections.Generic.Dictionary[string,object]') }
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if ($text.Trim().Length -eq 0) { return (New-Object 'System.Collections.Generic.Dictionary[string,object]') }
    $o = $script:Ser.DeserializeObject($text)
    if (-not ($o -is [System.Collections.IDictionary])) { throw "$path is not a JSON object" }
    return ,$o
}

# Back up, write UTF-8 without BOM, then read it back to prove the file is valid JSON.
function Write-JsonFile([string]$path, $obj, [string]$backupDir) {
    if ((Test-Path -LiteralPath $path) -and $backupDir) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir ([IO.Path]::GetFileName($path) + '.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak')) -Force
    }
    $json = (ConvertTo-PrettyJson $obj 0) + "`n"
    $tmp = $path + '.cssync-tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    [void]$script:Ser.DeserializeObject([IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8))   # throws if broken
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
}

function Test-OurHookGroup($group) {
    foreach ($h in @($group['hooks'])) { if ($h -is [System.Collections.IDictionary] -and ([string]$h['command']).Contains($script:Marker)) { return $true } }
    return $false
}

# Remove our entries from a settings-like dictionary; everyone else's hooks stay untouched.
function Remove-SyncHooks($settings) {
    if (-not $settings.ContainsKey('hooks') -or -not ($settings['hooks'] -is [System.Collections.IDictionary])) { return }
    $hooks = $settings['hooks']
    foreach ($ev in @($hooks.Keys)) {
        $kept = @(@($hooks[$ev]) | Where-Object { -not (Test-OurHookGroup $_) })
        if ($kept.Count -eq 0) { [void]$hooks.Remove($ev) } else { $hooks[$ev] = [object[]]$kept }
    }
    if ($hooks.Count -eq 0) { [void]$settings.Remove('hooks') }
}

# Stop / StopFailure / SessionEnd: sync now + follow-ups (a turn's last card is written after
# the hook). SessionStart: async. All print nothing (a SessionStart hook's stdout would enter
# Claude's context).
function Add-SyncHooks($settings, [string]$scriptPath) {
    $cmd = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ($scriptPath -replace '\\', '/') + '"'
    if (-not $settings.ContainsKey('hooks') -or -not ($settings['hooks'] -is [System.Collections.IDictionary])) { $settings['hooks'] = New-Object 'System.Collections.Generic.Dictionary[string,object]' }
    $hooks = $settings['hooks']
    # take out our old entries in place (removing and re-adding keys would reorder the file)
    $ours = 'Stop', 'StopFailure', 'SessionEnd', 'SessionStart'
    foreach ($ev in @($hooks.Keys)) {
        $kept = @(@($hooks[$ev]) | Where-Object { -not (Test-OurHookGroup $_) })
        if ($kept.Count -eq 0 -and $ours -notcontains $ev) { [void]$hooks.Remove($ev) } else { $hooks[$ev] = [object[]]$kept }
    }
    $make = {
        param($command, $async)
        $h = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        $h['type'] = 'command'; $h['command'] = $command; $h['timeout'] = 30
        if ($async) { $h['async'] = $true }
        $g = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        $g['hooks'] = [object[]]@($h)
        return ,$g
    }
    foreach ($ev in 'Stop', 'StopFailure', 'SessionEnd') {
        $list = @(); if ($hooks.ContainsKey($ev)) { $list = @($hooks[$ev]) }   # not '$list = if ...': that unrolls a 1-item array
        $hooks[$ev] = [object[]]($list + @(& $make ($cmd + ' -Followup') $false))
    }
    $list = @(); if ($hooks.ContainsKey('SessionStart')) { $list = @($hooks['SessionStart']) }
    $hooks['SessionStart'] = [object[]]($list + @(& $make $cmd $true))
}

# CC Switch (https://github.com/farion1231/cc-switch) rewrites settings.json from
# "provider config + common config" on every provider switch. Our hooks must live in the
# common config too, or the next switch removes them. Needs python (sqlite3).
# mode: 'install' copies settings.json's hooks into the common config; 'remove' removes ours.
function Update-CCSwitchHooks([string]$mode, [string]$settingsPath, [string]$backupDir) {
    $db = Join-Path $env:USERPROFILE '.cc-switch\cc-switch.db'
    if (-not (Test-Path -LiteralPath $db)) { return 'CC Switch not installed; nothing to do' }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { return "WARN: CC Switch found but python is not, so its common config was not updated. In CC Switch, add the 'hooks' block from $settingsPath to the Claude common config and tick 'write common config' on every Claude provider, or the next provider switch removes the hooks." }
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Copy-Item -LiteralPath $db -Destination (Join-Path $backupDir ('cc-switch.db.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak')) -Force
    $code = @'
import sqlite3, json, sys
db, mode, settings_path, marker = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
con = sqlite3.connect(db); cur = con.cursor()
row = cur.execute("select value from settings where key='common_config_claude'").fetchone()
common = json.loads(row[0]) if row and row[0] else {}
if mode == 'install':
    common['hooks'] = json.load(open(settings_path, encoding='utf-8')).get('hooks', {})
else:
    hooks = common.get('hooks') or {}
    for ev in list(hooks):
        hooks[ev] = [g for g in hooks[ev] if not any(marker in h.get('command', '') for h in g.get('hooks', []))]
        if not hooks[ev]: del hooks[ev]
    if hooks: common['hooks'] = hooks
    else: common.pop('hooks', None)
val = json.dumps(common, ensure_ascii=False, indent=2)
if row: cur.execute("update settings set value=? where key='common_config_claude'", (val,))
else: cur.execute("insert into settings(key, value) values('common_config_claude', ?)", (val,))
con.commit()
off = [n for n, m in cur.execute("select name, meta from providers where app_type='claude'") if (json.loads(m) if m else {}).get('commonConfigEnabled') is not True]
print(json.dumps({'off': off}))
'@
    $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), ('cssync-ccs-' + [guid]::NewGuid().ToString('N') + '.py'))
    [IO.File]::WriteAllText($tmp, $code, (New-Object Text.UTF8Encoding $false))
    try { $out = & $py.Source $tmp $db $mode $settingsPath $script:Marker 2>&1 | Select-Object -Last 1 } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    if ($LASTEXITCODE -ne 0) { return "WARN: could not update CC Switch's common config: $out" }
    $off = @(($out | ConvertFrom-Json).off)
    $msg = "CC Switch common config updated ($mode)"
    if ($mode -eq 'install' -and $off.Count -gt 0) { $msg += ". WARN: these Claude providers do not use the common config, so switching to them removes the hooks: " + ($off -join '; ') + " (tick 'write common config' on them in CC Switch)" }
    return $msg
}
