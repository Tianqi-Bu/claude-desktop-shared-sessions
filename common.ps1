# Shared helpers, dot-sourced by the three scripts. Windows PowerShell 5.1 compatible.
# Keep this file ASCII: PowerShell 5.1 reads BOM-less scripts in the system code page.

$script:UuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:MasterMarker = '.claude-session-link-master'   # marks the shared list so it stays the master across unlink/relink

# A strict JSON check for session records. Windows PowerShell 5.1 has JavaScriptSerializer
# (case-sensitive keys, no size cap once raised); elsewhere fall back to ConvertFrom-Json.
$script:JsonSer = $null
try {
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $script:JsonSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $script:JsonSer.MaxJsonLength = [int]::MaxValue
} catch {}
function Test-JsonObject([string]$text) {
    try {
        if ($script:JsonSer) { $o = $script:JsonSer.DeserializeObject($text); return ($o -is [System.Collections.IDictionary]) }
        $o = $text | ConvertFrom-Json -ErrorAction Stop; return ($o -is [psobject])
    } catch { return $false }
}

# Resolve a user-supplied path against the current location (not the process directory).
function Get-AbsolutePath([string]$p) {
    if ([IO.Path]::IsPathRooted($p)) { return [IO.Path]::GetFullPath($p).TrimEnd('\') }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $p)).TrimEnd('\')
}

# Same bytes? Files by hash; folders by relative paths + hashes of everything inside.
# Anything unreadable (e.g. locked by another program) counts as "different", so the item
# is reported and kept in the backup instead of aborting the run.
function Test-SameContent([string]$a, [string]$b) {
    try {
        if (-not (Test-Path -LiteralPath $b)) { return $false }
        $ia = Get-Item -LiteralPath $a -Force; $ib = Get-Item -LiteralPath $b -Force
        if ($ia.PSIsContainer -ne $ib.PSIsContainer) { return $false }
        if (-not $ia.PSIsContainer) { return (Get-FileHash -LiteralPath $a -ErrorAction Stop).Hash -eq (Get-FileHash -LiteralPath $b -ErrorAction Stop).Hash }
        $sig = {
            param($root)
            @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop | Sort-Object FullName | ForEach-Object {
                $_.FullName.Substring($root.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName -ErrorAction Stop).Hash }) -join '|'
        }
        return (& $sig $ia.FullName) -eq (& $sig $ib.FullName)
    } catch { return $false }
}

$script:MissingListHelp = "The backup folder only holds each login's folder from before linking, not the shared list itself. Either put the shared list back from your own backup, or run Unlink-ClaudeAccounts.ps1 -Apply -AllowEmpty to turn the broken links into empty folders and start over (a login's old folder can then be restored from claude-session-link-backup)."

function Test-IsLink([string]$path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return [bool]($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))
}

# claude-code-sessions folders of every Claude Desktop profile on this machine.
function Get-DefaultSessionRoots {
    $found = @()
    foreach ($p in @(Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\Packages" -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue)) {
        $r = Join-Path $p.FullName 'LocalCache\Roaming\Claude\claude-code-sessions'   # Microsoft Store (MSIX) install
        if (Test-Path -LiteralPath $r) { $found += $r }
    }
    if ($found.Count -eq 0) { $found += (Join-Path $env:APPDATA 'Claude\claude-code-sessions') }   # classic install
    $found += (Join-Path $env:LOCALAPPDATA 'Claude-3p\claude-code-sessions')                          # third-party / gateway profile
    return @($found | Where-Object { Test-Path -LiteralPath $_ })
}

# Normalise, de-duplicate, and refuse roots that are themselves links: a linked root
# makes one physical folder look like two and the master could be moved into a backup.
function Resolve-SessionRoots([string[]]$roots) {
    $out = @()
    foreach ($r in $roots) {
        $full = Get-AbsolutePath $r
        if (-not (Test-Path -LiteralPath $full)) { continue }
        if (Test-IsLink $full) { throw "Session root '$full' is itself a link. Remove that link first; this tool only links account/org folders." }
        if (-not ($out | Where-Object { $_ -ieq $full })) { $out += $full }
    }
    return ,$out
}

# A running Claude Desktop holds <userData>\lockfile open; an idle profile's lockfile
# can be opened (or does not exist).
function Test-ProfileRunning([string]$sessionRoot) {
    $lock = Join-Path ([IO.Path]::GetDirectoryName($sessionRoot)) 'lockfile'
    if (-not (Test-Path -LiteralPath $lock)) { return $false }
    try { $fs = [IO.File]::Open($lock, 'Open', 'Read', 'ReadWrite'); $fs.Close(); return $false } catch { return $true }
}

function Test-DesktopRunning([string[]]$roots, [bool]$checkProcesses) {
    foreach ($r in $roots) { if (Test-ProfileRunning $r) { return $true } }   # authoritative
    if ($checkProcesses) {
        # extra check on the real machine: a desktop-app process at a known install path.
        # Processes whose path cannot be read (e.g. an elevated CLI) are not counted; the
        # lockfile check above already covers every running profile.
        foreach ($p in @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue)) {
            $path = $null
            try { $path = $p.Path } catch {}
            if ($path -and ($path -match '\\WindowsApps\\Claude_' -or $path -match '\\AnthropicClaude\\')) { return $true }
        }
    }
    return $false
}

# Every <account>\<org> folder under the roots. Account folders that are links are skipped.
function Get-Leaves([string[]]$roots) {
    $leaves = @()
    for ($i = 0; $i -lt $roots.Count; $i++) {
        $root = $roots[$i]
        foreach ($acct in @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.PSIsContainer -and $_.Name -match $script:UuidPattern })) {
            if ($acct.Attributes -band [IO.FileAttributes]::ReparsePoint) { Write-Warning "SKIP    account folder $($acct.FullName) is a link; not touched"; continue }
            foreach ($org in @(Get-ChildItem -LiteralPath $acct.FullName -Force | Where-Object { $_.PSIsContainer -and $_.Name -match $script:UuidPattern })) {
                $isLink = [bool]($org.Attributes -band [IO.FileAttributes]::ReparsePoint)
                $leaves += [pscustomobject]@{
                    RootIndex = $i
                    Rel       = "$($acct.Name)\$($org.Name)"
                    Path      = $org.FullName.TrimEnd('\')
                    IsLink    = $isLink
                    Target    = $(if ($isLink) { ([string]($org.Target -join '')).TrimEnd('\') } else { '' })
                    Count     = @(Get-ChildItem -LiteralPath $org.FullName -Filter 'local_*.json' -Force -ErrorAction SilentlyContinue).Count
                    Marked    = (-not $isLink) -and (Test-Path -LiteralPath (Join-Path $org.FullName $script:MasterMarker))
                }
            }
        }
    }
    return ,$leaves
}

# Read a file without blocking the app: share read, write and delete, so the app's
# own tmp+rename saves never fail because we have the file open.
function Read-SharedBytes([string]$path) {
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms); return ,$ms.ToArray() } finally { $fs.Dispose() }
}

function Get-JsonField($obj, [string]$name) {
    if ($obj -is [System.Collections.IDictionary]) { if ($obj.ContainsKey($name)) { return $obj[$name] } else { return $null } }
    return $obj.$name
}

# Facts about one session card, from its bytes.
#   Usable:   the app can read it - no UTF-8 BOM, starts with '{', parses as a JSON object
#   Damaged:  the app marked it transcriptUnavailable (anthropics/claude-code#63082). A card
#             WITHOUT cliSessionId is normal (e.g. right after /clear) and is not damaged.
#   Cli:      cliSessionId, the conversation file the card resumes
#   Prior:    conversation files this card has moved on from (priorCliSessionIds and
#             preClearCliSessionId); a copy still pointing at one of them is out of date
function Get-RecordInfoFromBytes([byte[]]$bytes, [datetime]$writeTimeUtc) {
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $trim = $text.TrimStart([char[]]@(' ', "`t", "`r", "`n"))
    $obj = $null
    if (-not $bom -and $trim.Length -gt 0 -and $trim[0] -eq [char]'{') {
        try {
            if ($script:JsonSer) { $o = $script:JsonSer.DeserializeObject($text); if ($o -is [System.Collections.IDictionary]) { $obj = $o } }
            else { $o = $text | ConvertFrom-Json -ErrorAction Stop; if ($o -is [psobject]) { $obj = $o } }
        } catch { $obj = $null }
    }
    $cli = ''; $prior = @(); $act = [int64]0; $damaged = $false
    if ($obj -ne $null) {
        $v = Get-JsonField $obj 'cliSessionId'; if ($v) { $cli = [string]$v }
        foreach ($p in @(Get-JsonField $obj 'priorCliSessionIds')) { if ($p) { $prior += [string]$p } }
        $v = Get-JsonField $obj 'preClearCliSessionId'; if ($v) { $prior += [string]$v }
        $v = Get-JsonField $obj 'lastActivityAt'; if ($v -ne $null) { try { $act = [int64]$v } catch {} }
        $damaged = (Get-JsonField $obj 'transcriptUnavailable') -eq $true
    }
    [pscustomobject]@{
        Usable    = ($obj -ne $null)
        Damaged   = $damaged
        Healthy   = (($obj -ne $null) -and -not $damaged)
        Cli       = $cli
        Prior     = $prior
        Activity  = $act
        WriteTime = $writeTimeUtc
    }
}

function Get-RecordInfo([string]$path) {
    $bytes = [byte[]]@()
    try { $bytes = Read-SharedBytes $path } catch {}
    $wt = [datetime]::MinValue
    try { $wt = [IO.File]::GetLastWriteTimeUtc($path) } catch {}
    return Get-RecordInfoFromBytes $bytes $wt
}

# Pick the copy every login should get. Order:
#   1. readable by the app
#   2. not out of date: a copy whose cliSessionId another copy lists as a prior / pre-clear
#      conversation must never win (that would resume an old point of the conversation)
#   3. not damaged (transcriptUnavailable)
#   4. newer lastActivityAt, then newer file time
# $copies: objects with an .Info property from Get-RecordInfo*. Returns $null if none is readable.
function Select-BestCopy($copies) {
    $usable = @($copies | Where-Object { $_.Info.Usable })
    if ($usable.Count -eq 0) { return $null }
    $stale = New-Object bool[] $usable.Count
    for ($i = 0; $i -lt $usable.Count; $i++) {
        $ci = $usable[$i].Info.Cli
        if (-not $ci) { continue }
        for ($j = 0; $j -lt $usable.Count; $j++) {
            $o = $usable[$j].Info
            if ($o.Cli -ne $ci -and ($o.Prior -contains $ci)) { $stale[$i] = $true; break }
        }
    }
    $bi = 0
    for ($i = 1; $i -lt $usable.Count; $i++) {
        $a = $usable[$i].Info; $b = $usable[$bi].Info
        $better = if ($stale[$i] -ne $stale[$bi]) { -not $stale[$i] } elseif ($a.Damaged -ne $b.Damaged) { -not $a.Damaged } elseif ($a.Activity -ne $b.Activity) { $a.Activity -gt $b.Activity } else { $a.WriteTime -gt $b.WriteTime }
        if ($better) { $bi = $i }
    }
    return $usable[$bi]
}
