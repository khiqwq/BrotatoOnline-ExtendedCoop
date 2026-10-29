<#
.SYNOPSIS
  Static checks for every change: manifest, lock/compatibility consistency,
  package whitelist, GDScript source rules and (when the engine copy exists)
  compilation of the pure rule modules. Passing here does not prove the game
  API works; see tools/test.ps1 -Suite Integration.
.PARAMETER UpdateCompatibility
  Regenerate compatibility.json from project.lock.json instead of failing.
#>
[CmdletBinding()]
param([switch]$UpdateCompatibility)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force

$repo = Get-RepoRoot
$lock = Read-Lock
$modId = $lock.extension.id
$modDir = Join-Path $repo "mods-unpacked\$modId"

# Manifest
$manifestPath = Join-Path $modDir 'manifest.json'
if (-not (Test-Path $modDir)) { Add-Result FAIL 'mod directory' "mods-unpacked/$modId missing" }
elseif (-not (Test-Path $manifestPath)) { Add-Result FAIL 'manifest' 'manifest.json missing' }
else {
    try {
        $m = Get-Content -Raw -Encoding utf8 $manifestPath | ConvertFrom-Json
        $problems = @()
        if ("$($m.namespace)-$($m.name)" -ne $modId) { $problems += "id $($m.namespace)-$($m.name) != $modId" }
        if ($m.version_number -ne $lock.extension.version) { $problems += "version $($m.version_number) != lock $($lock.extension.version)" }
        if ($m.version_number -notmatch '^\d+\.\d+\.\d+$') { $problems += 'version_number must be semver x.y.z' }
        if (-not ($m.dependencies -contains 'six666-BrotatoOnline')) { $problems += 'must depend on six666-BrotatoOnline' }
        if (-not ($m.extra.godot.compatible_game_version -contains $lock.game.version)) { $problems += "compatible_game_version lacks $($lock.game.version)" }
        if (-not ($m.extra.godot.compatible_mod_loader_version -contains $lock.mod_loader.version)) { $problems += "compatible_mod_loader_version lacks $($lock.mod_loader.version)" }
        if ($problems) { Add-Result FAIL 'manifest' ($problems -join '; ') } else { Add-Result PASS 'manifest' }
    }
    catch { Add-Result FAIL 'manifest' "invalid JSON: $_" }
}

# compatibility.json is generated from the lock; the two must never disagree.
$compat = [ordered]@{
    schema                     = 1
    extension_id               = $modId
    extension_version          = $lock.extension.version
    network_capability_version = $lock.extension.network_capability_version
    save_schema_version        = $lock.extension.save_schema_version
    game_versions              = @($lock.game.version)
    engine_versions            = @($lock.game.engine_version)
    mod_loader_versions        = @($lock.mod_loader.version)
    upstream                   = @($lock.upstream_mods | ForEach-Object {
            [ordered]@{ id = $_.id; version = $_.version; normalized_fingerprint = $_.normalized_fingerprint; role = $_.role }
        })
}
$compatJson = ($compat | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"
$compatPath = Join-Path $modDir 'compatibility.json'
if ($UpdateCompatibility) {
    [IO.File]::WriteAllText($compatPath, $compatJson + "`n", [Text.UTF8Encoding]::new($false))
    Add-Result PASS 'compatibility.json' 'regenerated from project.lock.json'
}
elseif (-not (Test-Path $compatPath)) { Add-Result FAIL 'compatibility.json' 'missing; run tools/check.ps1 -UpdateCompatibility' }
else {
    $current = (Get-Content -Raw -Encoding utf8 $compatPath) -replace "`r`n", "`n"
    if ($current.TrimEnd() -eq $compatJson.TrimEnd()) { Add-Result PASS 'compatibility.json matches lock' }
    else { Add-Result FAIL 'compatibility.json matches lock' 'differs; review the lock change, then run -UpdateCompatibility' }
}

# Package whitelist: every mod file must be packaged or explicitly excluded.
function Test-Glob([string]$rel, [string]$glob) {
    $rx = '^' + ([regex]::Escape($glob) -replace '\\\*\\\*/', '(.*/)?' -replace '\\\*', '[^/]*') + '$'
    return $rel -match $rx
}
if (Test-Path $modDir) {
    $unlisted = @()
    Get-ChildItem -LiteralPath $modDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($repo.Length + 1) -replace '\\', '/'
        $excluded = @($lock.package.excluded_dirs | Where-Object { $rel.StartsWith("$_/") }).Count -gt 0
        $listed = @($lock.package.whitelist | Where-Object { Test-Glob $rel $_ }).Count -gt 0
        if (-not $listed -and -not $excluded) { $unlisted += $rel }
    }
    if ($unlisted) { Add-Result FAIL 'package whitelist' ("not whitelisted: " + ($unlisted -join ', ')) }
    else { Add-Result PASS 'package whitelist' }
}

# GDScript source rules (Godot 3 project conventions).
$gdFiles = @(Get-ChildItem -Path (Join-Path $repo 'mods-unpacked'), (Join-Path $repo 'tests') -Recurse -File -Filter *.gd -ErrorAction SilentlyContinue)
$ruleProblems = @()
foreach ($f in $gdFiles) {
    $rel = $f.FullName.Substring($repo.Length + 1) -replace '\\', '/'
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $ruleProblems += "$rel has UTF-8 BOM" }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Contains("`r")) { $ruleProblems += "$rel has CRLF line endings" }
    $lineNo = 0
    foreach ($line in $text -split "`n") {
        $lineNo++
        if ($line -match '^ +\S') { $ruleProblems += "${rel}:$lineNo indents with spaces" }
        if ($rel.StartsWith('mods-unpacked/') -and $line -match '^\s*class_name\s') { $ruleProblems += "${rel}:$lineNo uses class_name (mods must use preload constants)" }
        # An installed extension owns its parent's path, so preloading an extension
        # makes it its own parent at runtime (ADR-001); only mod_main installs them.
        if ($rel.StartsWith('mods-unpacked/') -and -not $rel.EndsWith('/mod_main.gd') -and $line -match '(pre)?load\(\s*"res://mods-unpacked/[^"]+/(extensions|debug/probe_extensions)/') { $ruleProblems += "${rel}:$lineNo loads an extension script (use scripts/ for shared code)" }
    }
}
if ($ruleProblems) { Add-Result FAIL 'gdscript source rules' ($ruleProblems -join '; ') } else { Add-Result PASS 'gdscript source rules' "$($gdFiles.Count) files" }

# Compile pure modules and tests in the harness project (no game files needed).
if (-not (Get-EnginePath)) {
    Add-Result SKIPPED 'gdscript compile' 'engine copy missing; run tools/setup.ps1'
}
else {
    $roots = @("res://mods-unpacked/$modId/scripts/core", "res://mods-unpacked/$modId/scripts/network", "res://mods-unpacked/$modId/scripts/persistence", "res://mods-unpacked/$modId/scripts/diagnostics", 'res://tests/unit', 'res://tests/runner') -join ','
    $log = Get-LocalDir "reports\compile-$PID.log"
    New-Item -ItemType Directory -Force (Split-Path $log -Parent) | Out-Null
    $r = Invoke-Engine -ProjectPath $repo -Arguments @('-s', 'res://tests/runner/compile_check.gd', "--roots=$roots") -UserDataDir (Get-LocalDir "userdata\check-$PID") -TimeoutSec 180 -LogPath $log
    $bad = @($r.Output -split "`n" | Where-Object { $_ -match '^COMPILE_FAIL|SCRIPT ERROR' })
    $summary = ($r.Output -split "`n" | Where-Object { $_ -match '^COMPILE_SUMMARY' }) -join ''
    if ($r.TimedOut) { Add-Result FAIL 'gdscript compile' 'engine timed out' }
    elseif ($bad) { Add-Result FAIL 'gdscript compile' (($bad | Select-Object -First 10) -join ' | ') }
    elseif ($summary -notmatch 'files=([1-9]\d*) failed=0' -or $r.ExitCode -ne 0) { Add-Result FAIL 'gdscript compile' "no usable COMPILE_SUMMARY (exit $($r.ExitCode)); see $log" }
    else { Add-Result PASS 'gdscript compile' $summary.Trim() }
}

Complete-Run -Title 'check' -ReportPath (Get-LocalDir 'reports\check.json')
