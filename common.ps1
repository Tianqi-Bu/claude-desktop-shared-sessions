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

# Facts about one session record, read as bytes (no JSON parser: records can hold text
# PowerShell 5.1 mis-decodes, and the app skips files a parser would happily accept).
#   Usable:  the app can read it - non-empty, no UTF-8 BOM, starts with '{'
#   Healthy: still linked to its transcript; the app strips cliSessionId and sets
#            transcriptUnavailable when it cannot find the transcript (anthropics/claude-code#63082)
function Get-RecordInfo([string]$path) {
    $bytes = [byte[]]@()
    try { $bytes = [IO.File]::ReadAllBytes($path) } catch {}
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    # the app JSON.parses the file: first byte must be '{' (ASCII whitespace allowed) and the whole thing must parse
    $trim = $text.TrimStart([char[]]@(' ', "`t", "`r", "`n"))
    $usable = (-not $bom) -and $trim.Length -gt 0 -and $trim[0] -eq [char]'{' -and (Test-JsonObject $text)
    $healthy = $usable -and ($text -match '"cliSessionId"\s*:\s*"[0-9a-fA-F-]{36}"') -and ($text -notmatch '"transcriptUnavailable"\s*:\s*true')
    $m = [regex]::Match($text, '"lastActivityAt"\s*:\s*(\d+)')
    [pscustomobject]@{
        Usable    = $usable
        Healthy   = $healthy
        Activity  = $(if ($m.Success) { [int64]$m.Groups[1].Value } else { [int64]0 })
        WriteTime = (Get-Item -LiteralPath $path -Force).LastWriteTimeUtc
    }
}

# Should the incoming copy of a record replace the master's copy?
# usable beats unusable, healthy beats damaged, then newer lastActivityAt, then newer file time.
function Test-IncomingWins([string]$incoming, [string]$current) {
    $a = Get-RecordInfo $incoming; $b = Get-RecordInfo $current
    if ($a.Usable -ne $b.Usable) { return $a.Usable }
    if ($a.Healthy -ne $b.Healthy) { return $a.Healthy }
    if ($a.Activity -ne $b.Activity) { return $a.Activity -gt $b.Activity }
    return $a.WriteTime -gt $b.WriteTime
}
