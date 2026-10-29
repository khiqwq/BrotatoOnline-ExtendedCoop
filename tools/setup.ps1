<#
.SYNOPSIS
  Verify the local Brotato install against project.lock.json and prepare the
  ignored .local/ integration environment. Never writes into the game or
  workshop folders and never replaces upstream mods.
.EXAMPLE
  pwsh ./tools/setup.ps1 -GamePath "E:\SteamLibrary\steamapps\common\Brotato"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GamePath,
    [string]$WorkshopPath = '',
    [string]$Python = 'python',
    [switch]$SkipRecovery
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force

$repo = Get-RepoRoot
$local = Get-LocalDir
$lock = Read-Lock
New-Item -ItemType Directory -Force $local | Out-Null

# 1. Game files
$GamePath = (Resolve-Path $GamePath).Path
$gameOk = $true
foreach ($prop in $lock.game.files.PSObject.Properties) {
    $f = Join-Path $GamePath $prop.Name
    if (-not (Test-Path $f)) { Add-Result FAIL "game file $($prop.Name)" 'missing'; $gameOk = $false; continue }
    $h = Get-FileSha256 $f
    if ($h -eq $prop.Value) { Add-Result PASS "game file $($prop.Name)" }
    else { Add-Result FAIL "game file $($prop.Name)" "sha256 $h differs from lock"; $gameOk = $false }
}
foreach ($d in $lock.dlc) {
    $f = Join-Path $GamePath $d.file
    if (-not (Test-Path $f)) { Add-Result SKIPPED "dlc $($d.name)" 'not installed'; continue }
    $h = Get-FileSha256 $f
    if ($h -eq $d.sha256) { Add-Result PASS "dlc $($d.name)" } else { Add-Result FAIL "dlc $($d.name)" "sha256 $h differs from lock" }
}

# 2. Workshop mods (read only)
if (-not $WorkshopPath) {
    $WorkshopPath = Join-Path $GamePath "..\..\workshop\content\$($lock.game.app_id)"
}
$upstream = @{}
foreach ($m in $lock.upstream_mods) {
    $zip = Join-Path $WorkshopPath "$($m.workshop_id)\$($m.zip)"
    if (-not (Test-Path $zip)) {
        $status = if ($m.role -eq 'required') { 'FAIL' } else { 'SKIPPED' }
        Add-Result $status "workshop $($m.id)" "not found at $zip"
        continue
    }
    $fp = Get-ZipModFingerprint -ZipPath $zip -ModId $m.id
    if ($fp.Fingerprint -eq $m.normalized_fingerprint) { Add-Result PASS "workshop $($m.id) fingerprint" }
    else { Add-Result FAIL "workshop $($m.id) fingerprint" "$($fp.Fingerprint) ($($fp.FileCount) files) differs from lock" }
    $dest = Get-LocalDir "upstream\workshop-$($m.workshop_id)"
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force $dest | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $dest
    $upstream[$m.id] = @{ zip = $zip; unpacked = (Join-Path $dest "mods-unpacked\$($m.id)"); fingerprint = $fp.Fingerprint }
}

# 3. Engine copy for headless tests (same binary as the game, outside the game folder)
$engineDir = Get-LocalDir 'engine'
New-Item -ItemType Directory -Force $engineDir | Out-Null
foreach ($name in 'Brotato.exe', 'steam_api64.dll') {
    $src = Join-Path $GamePath $name
    $dst = Join-Path $engineDir $name
    if (-not (Test-Path $dst) -or (Get-FileSha256 $dst) -ne (Get-FileSha256 $src)) { Copy-Item -LiteralPath $src -Destination $dst -Force }
}
$enginePath = Join-Path $engineDir 'Brotato.exe'
Add-Result PASS 'engine copy' $engineDir

# 4. Recovered game scripts and the integration root (local audit only)
$recovered = $null
if ($SkipRecovery) {
    Add-Result SKIPPED 'recovery' '-SkipRecovery given'
}
elseif (-not (Get-Command $Python -ErrorAction SilentlyContinue)) {
    Add-Result SKIPPED 'recovery' "python not found ('$Python'); integration suite will be skipped"
}
else {
    $rec = Join-Path $repo 'tools\recovery'
    $work = Get-LocalDir 'recovery'
    New-Item -ItemType Directory -Force $work | Out-Null
    & $Python -I (Join-Path $rec 'pe_string_tables.py') (Join-Path $GamePath 'Brotato.exe') (Join-Path $work 'all_tables.json') | Out-Null
    & $Python -I -c "import json,sys; d=json.load(open(sys.argv[1])); f=[t for t in d['builtin_funcs'] if 'deep_equal' in t]; assert len(d['token_names'])==1 and len(f)==1; json.dump({'token_names': d['token_names'][0], 'builtin_funcs': f[0]}, open(sys.argv[2],'w'), indent=1)" (Join-Path $work 'all_tables.json') (Join-Path $work 'engine_tables.json')
    if ($LASTEXITCODE -ne 0) { Add-Result FAIL 'recovery tables' 'token/builtin tables not found in engine binary' }
    else {
        $root = Get-LocalDir 'integration\root'
        if (Test-Path $root) { Remove-Item -Recurse -Force $root }
        New-Item -ItemType Directory -Force $root | Out-Null
        $packs = @(Join-Path $GamePath 'Brotato.pck') + @($lock.dlc | ForEach-Object { Join-Path $GamePath $_.file } | Where-Object { Test-Path $_ })
        $failed = $false
        foreach ($pck in $packs) {
            $tmp = Get-LocalDir ("integration\pack-" + [IO.Path]::GetFileNameWithoutExtension($pck))
            if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
            & $Python -I (Join-Path $rec 'pck_extract.py') $pck $tmp '*' | Out-Null
            & $Python -I (Join-Path $rec 'gdc_detokenize.py') (Join-Path $work 'engine_tables.json') $tmp $tmp | Out-Null
            if ($LASTEXITCODE -ne 0) { $failed = $true }
            # Base pack first; later packs never overwrite base files.
            Get-ChildItem -LiteralPath $tmp -Recurse -File | ForEach-Object {
                $rel = $_.FullName.Substring($tmp.Length + 1)
                if ($rel -like '*.gdc' -or $rel -like '*.gd.remap' -or $rel -eq 'project.binary') { return }
                $dst = Join-Path $root $rel
                if (Test-Path $dst) { return }
                New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
                Move-Item -LiteralPath $_.FullName -Destination $dst
            }
            if ($pck -like '*Brotato.pck') {
                & $Python -I (Join-Path $rec 'project_binary.py') (Join-Path $tmp 'project.binary') (Join-Path $root 'project.godot') (Join-Path $work 'project_settings_subset.json') $root | Out-Null
            }
            Remove-Item -Recurse -Force $tmp
        }
        New-Item -ItemType Directory -Force (Join-Path $root '__validation__') | Out-Null
        Copy-Item (Join-Path $rec 'validation\*.gd') (Join-Path $root '__validation__')
        foreach ($id in $upstream.Keys) {
            $dst = Join-Path $root "mods-unpacked\$id"
            New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
            Copy-Item -Recurse -LiteralPath $upstream[$id].unpacked -Destination $dst
        }
        if ($failed) { Add-Result FAIL 'recovery' 'some scripts could not be detokenized' }
        else { Add-Result PASS 'recovery' $root; $recovered = $root }
    }
}

# 5. Local config consumed by check/test
$config = [ordered]@{
    generated     = (Get-Date).ToString('s')
    game_path     = $GamePath
    workshop_path = (Resolve-Path $WorkshopPath -ErrorAction SilentlyContinue).Path
    engine_path   = $enginePath
    game_matches_lock = $gameOk
    integration_root  = $recovered
    upstream      = $upstream
}
$config | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Get-LocalDir 'config.json')
Add-Result PASS 'local config' (Get-LocalDir 'config.json')
Complete-Run -Title 'setup' -ReportPath (Get-LocalDir 'reports\setup.json')
