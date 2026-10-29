Set-StrictMode -Version Latest

# Shared helpers for tools/*.ps1. Every entry point reports PASS/FAIL/SKIPPED lines
# and exits non-zero when anything failed; SKIPPED never counts as PASS.

$script:Results = [System.Collections.Generic.List[object]]::new()

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Get-LocalDir {
    param([string]$Child = '')
    $dir = Join-Path (Get-RepoRoot) '.local'
    if ($Child) { $dir = Join-Path $dir $Child }
    return $dir
}

function Add-Result {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'SKIPPED')][string]$Status,
        [Parameter(Mandatory)][string]$Name,
        [string]$Detail = ''
    )
    $script:Results.Add([pscustomobject]@{ Status = $Status; Name = $Name; Detail = $Detail })
    $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIPPED = 'Yellow' }[$Status]
    $line = "[$Status] $Name"
    if ($Detail) { $line += " - $Detail" }
    Write-Host $line -ForegroundColor $color
}

function Complete-Run {
    param([string]$Title = 'run', [string]$ReportPath = '')
    $fail = @($script:Results | Where-Object Status -eq 'FAIL').Count
    $skip = @($script:Results | Where-Object Status -eq 'SKIPPED').Count
    $pass = @($script:Results | Where-Object Status -eq 'PASS').Count
    Write-Host ("{0}: {1} passed, {2} failed, {3} skipped" -f $Title, $pass, $fail, $skip)
    if ($ReportPath) {
        $dir = Split-Path $ReportPath -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $script:Results | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $ReportPath
    }
    if ($fail -gt 0) { exit 1 }
    exit 0
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

# Normalized fingerprint of a mod: independent of zip timestamps and compression.
# Lines "relative/path<TAB>sha256(content)\n" for every file under
# mods-unpacked/<ModId>/, sorted ordinally, hashed with SHA-256.
# scripts/compatibility/upstream_fingerprint.gd implements the same rule at runtime.
function Get-ModFingerprintFromEntries {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Entries)
    $keys = [string[]]@($Entries.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($k in $keys) { [void]$sb.Append($k).Append("`t").Append($Entries[$k]).Append("`n") }
    return [pscustomobject]@{
        Fingerprint = Get-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes($sb.ToString()))
        FileCount   = $keys.Count
    }
}

function Get-ZipModFingerprint {
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$ModId)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $prefix = "mods-unpacked/$ModId/"
    $entries = [ordered]@{}
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($e in $zip.Entries) {
            $name = $e.FullName -replace '\\', '/'
            if ($name.EndsWith('/') -or -not $name.StartsWith($prefix)) { continue }
            $ms = [System.IO.MemoryStream]::new()
            $s = $e.Open()
            try { $s.CopyTo($ms) } finally { $s.Dispose() }
            $entries[$name.Substring($prefix.Length)] = Get-Sha256Hex $ms.ToArray()
        }
    }
    finally { $zip.Dispose() }
    return Get-ModFingerprintFromEntries $entries
}

function Get-DirectoryModFingerprint {
    param([Parameter(Mandatory)][string]$ModDir)
    $root = (Resolve-Path $ModDir).Path.TrimEnd('\', '/')
    $entries = [ordered]@{}
    Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length + 1) -replace '\\', '/'
        $entries[$rel] = Get-FileSha256 $_.FullName
    }
    return Get-ModFingerprintFromEntries $entries
}

function Read-Lock {
    $path = Join-Path (Get-RepoRoot) 'project.lock.json'
    return Get-Content -Raw -Encoding utf8 $path | ConvertFrom-Json
}

function Read-LocalConfig {
    $path = Get-LocalDir 'config.json'
    if (-not (Test-Path $path)) { return $null }
    return Get-Content -Raw -Encoding utf8 $path | ConvertFrom-Json
}

function Get-EnginePath {
    $cfg = Read-LocalConfig
    if ($null -eq $cfg) { return $null }
    $exe = $cfg.engine_path
    if ($exe -and (Test-Path $exe)) { return $exe }
    return $null
}

# Runs the target engine copy headless with user:// redirected to an isolated
# directory, so tests can never touch the player's real saves.
function Invoke-Engine {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$UserDataDir,
        [int]$TimeoutSec = 300,
        [string]$LogPath = ''
    )
    $exe = Get-EnginePath
    if (-not $exe) { throw 'engine copy missing; run tools/setup.ps1 first' }
    if (-not (Test-Path $UserDataDir)) { New-Item -ItemType Directory -Force $UserDataDir | Out-Null }
    $psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = Split-Path $exe -Parent
    $psi.Environment['APPDATA'] = (Resolve-Path $UserDataDir).Path
    $psi.Environment.Remove('XDG_CONFIG_HOME') | Out-Null
    foreach ($a in @('--no-window', '--path', $ProjectPath) + $Arguments) { $psi.ArgumentList.Add($a) }
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $p.Kill($true)
        $p.WaitForExit()
        $timedOut = $true
    }
    else { $timedOut = $false }
    $text = $outTask.Result + $errTask.Result
    if ($LogPath) { Set-Content -Encoding utf8 -LiteralPath $LogPath -Value $text }
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $text; TimedOut = $timedOut }
}

# Files of the extension selected by the lock whitelist, as repo-relative paths.
# -IncludeDebug adds the excluded debug/ folder; only development builds use it.
function Get-PackageFileList {
    param([switch]$IncludeDebug)
    $repo = Get-RepoRoot
    $lock = Read-Lock
    $modDir = Join-Path $repo "mods-unpacked\$($lock.extension.id)"
    $files = [System.Collections.Generic.List[string]]::new()
    Get-ChildItem -LiteralPath $modDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($repo.Length + 1) -replace '\\', '/'
        $excluded = @($lock.package.excluded_dirs | Where-Object { $rel.StartsWith("$_/") }).Count -gt 0
        if ($excluded) {
            if ($IncludeDebug) { $files.Add($rel) }
            return
        }
        foreach ($glob in $lock.package.whitelist) {
            $rx = '^' + ([regex]::Escape($glob) -replace '\\\*\\\*/', '(.*/)?' -replace '\\\*', '[^/]*') + '$'
            if ($rel -match $rx) { $files.Add($rel); break }
        }
    }
    $arr = $files.ToArray()
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return , $arr
}

# Deterministic zip: ordinal entry order, fixed timestamp, LF-normalised text is
# whatever the repo holds (.gitattributes), no directory entries.
function New-DeterministicZip {
    param([Parameter(Mandatory)][string[]]$RelativePaths, [Parameter(Mandatory)][string]$OutPath)
    Add-Type -AssemblyName System.IO.Compression
    $repo = Get-RepoRoot
    $stamp = [DateTimeOffset]::Parse((Read-Lock).package.zip_entry_timestamp)
    $dir = Split-Path $OutPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    if (Test-Path $OutPath) { Remove-Item -Force $OutPath }
    $fs = [System.IO.File]::Open($OutPath, [System.IO.FileMode]::CreateNew)
    try {
        $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($rel in $RelativePaths) {
                if ($rel -match '(^|/)\.\.(/|$)' -or $rel.StartsWith('/')) { throw "unsafe package path: $rel" }
                $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $stamp
                $es = $entry.Open()
                try {
                    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repo $rel))
                    $es.Write($bytes, 0, $bytes.Length)
                }
                finally { $es.Dispose() }
            }
        }
        finally { $zip.Dispose() }
    }
    finally { $fs.Dispose() }
    return Get-FileSha256 $OutPath
}

Export-ModuleMember -Function *
