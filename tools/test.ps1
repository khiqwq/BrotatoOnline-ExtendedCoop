<#
.SYNOPSIS
  Run test suites with the target engine copy.
    Unit         rule tests in tests/unit (no game files needed beyond the engine copy)
    Integration  compiles the extension against the real upstream scripts and runs
                 tests/integration inside the recovered game root prepared by setup.ps1
  Missing prerequisites produce SKIPPED with a reason, never PASS.
.EXAMPLE
  pwsh ./tools/test.ps1 -Suite Unit
  pwsh ./tools/test.ps1 -Suite Integration -GamePath "E:\SteamLibrary\steamapps\common\Brotato"
#>
[CmdletBinding()]
param(
    [ValidateSet('Unit', 'Integration', 'RunnerSelfTest')][string]$Suite = 'Unit',
    [string]$GamePath = '',
    [string]$Filter = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force

$repo = Get-RepoRoot
$lock = Read-Lock
$modId = $lock.extension.id
$reports = Get-LocalDir 'reports'
New-Item -ItemType Directory -Force $reports | Out-Null

function Invoke-Suite([string]$ProjectPath, [string]$SuiteDir, [string]$Name, [bool]$ExpectFailure = $false) {
    # Per-process user data and report names so parallel runs never share files.
    if ($Filter) { $Name = "$Name-" + ($Filter -replace '[^A-Za-z0-9_]', '_') }
    $userData = Get-LocalDir "userdata\$Name-$PID"
    if (Test-Path $userData) { Remove-Item -Recurse -Force $userData }
    $engineArgs = @('-s', 'res://tests/runner/run_tests.gd', "--suite=$SuiteDir")
    if ($Filter) { $engineArgs += "--filter=$Filter" }
    $r = Invoke-Engine -ProjectPath $ProjectPath -Arguments $engineArgs -UserDataDir $userData -TimeoutSec 600 -LogPath (Join-Path $reports "$Name.log")
    $lines = $r.Output -split "`n"
    $scriptErrors = @($lines | Where-Object { $_ -match 'SCRIPT ERROR' })
    $summary = ($lines | Where-Object { $_ -match '^TEST_SUMMARY' }) -join ''
    foreach ($l in $lines | Where-Object { $_ -match '^TEST_RESULT FAIL' }) { Write-Host $l -ForegroundColor Red }
    $resultFile = Get-ChildItem -Path $userData -Recurse -Filter test_results.json -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($resultFile) { Copy-Item $resultFile.FullName (Join-Path $reports "$Name.results.json") -Force }
    if ($ExpectFailure) {
        # Runner self-test: the deliberately failing fixtures must be reported as failures.
        if ($r.ExitCode -ne 0 -and $summary -match 'failed=[1-9]') { Add-Result PASS "suite $Name" "runner reports failures ($($summary.Trim()))" }
        else { Add-Result FAIL "suite $Name" "runner did not report the expected failures ($($summary.Trim()))" }
        return
    }
    if ($r.TimedOut) { Add-Result FAIL "suite $Name" 'engine timed out' }
    elseif ($scriptErrors) { Add-Result FAIL "suite $Name" ("script errors: " + (($scriptErrors | Select-Object -First 5) -join ' | ')) }
    elseif ($r.ExitCode -ne 0 -or $summary -notmatch 'passed=([1-9]\d*) failed=0') { Add-Result FAIL "suite $Name" ($summary.Trim() + " exit=$($r.ExitCode)") }
    else { Add-Result PASS "suite $Name" $summary.Trim() }
}

if (-not (Get-EnginePath)) {
    Add-Result SKIPPED "suite $Suite" 'engine copy missing; run tools/setup.ps1 -GamePath <game>'
    Complete-Run -Title 'test' -ReportPath (Join-Path $reports "test-$Suite.json")
}

switch ($Suite) {
    'Unit' { Invoke-Suite -ProjectPath $repo -SuiteDir 'unit' -Name 'unit' }
    'RunnerSelfTest' { Invoke-Suite -ProjectPath $repo -SuiteDir 'runner_selftest' -Name 'runner_selftest' -ExpectFailure $true }
    'Integration' {
        $cfg = Read-LocalConfig
        if ($GamePath -and $cfg -and ((Resolve-Path $GamePath).Path -ne $cfg.game_path)) {
            Add-Result FAIL 'integration environment' "setup was run for $($cfg.game_path); rerun tools/setup.ps1 -GamePath $GamePath"
        }
        elseif (-not $cfg -or -not $cfg.integration_root -or -not (Test-Path $cfg.integration_root)) {
            Add-Result SKIPPED 'suite integration' 'no recovered integration root; run tools/setup.ps1 -GamePath <game> (needs python)'
        }
        else {
            $root = $cfg.integration_root
            if (-not $cfg.game_matches_lock) { Add-Result FAIL 'integration environment' 'installed game differs from project.lock.json' }
            # The recovered root is shared: one integration run at a time (released on exit).
            $mutex = [System.Threading.Mutex]::new($false, 'Local\CoopPlusOnlineExtendedCoopIntegration')
            try { $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(20)) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
            if (-not $acquired) {
                Add-Result FAIL 'integration environment' 'another integration run held the lock for 20 minutes'
                Complete-Run -Title 'test' -ReportPath (Join-Path $reports "test-$Suite.json")
            }
            # Fresh copy of this extension and the test harness into the recovered root.
            $dst = Join-Path $root "mods-unpacked\$modId"
            if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
            Copy-Item -Recurse (Join-Path $repo "mods-unpacked\$modId") $dst
            $testsDst = Join-Path $root 'tests'
            if (Test-Path $testsDst) { Remove-Item -Recurse -Force $testsDst }
            New-Item -ItemType Directory -Force $testsDst | Out-Null
            Copy-Item -Recurse (Join-Path $repo 'tests\runner'), (Join-Path $repo 'tests\integration'), (Join-Path $repo 'tests\fixtures') $testsDst -ErrorAction SilentlyContinue
            $r = Invoke-Engine -ProjectPath $root -Arguments @('-s', 'res://tests/runner/compile_check.gd', "--roots=res://mods-unpacked/$modId") -UserDataDir (Get-LocalDir 'userdata\integration-compile') -TimeoutSec 600 -LogPath (Join-Path $reports 'integration-compile.log')
            $bad = @($r.Output -split "`n" | Where-Object { $_ -match '^COMPILE_FAIL' })
            $summary = ($r.Output -split "`n" | Where-Object { $_ -match '^COMPILE_SUMMARY' }) -join ''
            # An engine run that printed nothing (or compiled nothing) is a failure, not a pass.
            if ($bad) { Add-Result FAIL 'extension compiles against upstream' (($bad | Select-Object -First 10) -join ' | ') }
            elseif ($summary -notmatch 'files=([1-9]\d*) failed=0' -or $r.ExitCode -ne 0) { Add-Result FAIL 'extension compiles against upstream' ("no usable COMPILE_SUMMARY (exit $($r.ExitCode), timed out: $($r.TimedOut)); see integration-compile.log") }
            else { Add-Result PASS 'extension compiles against upstream' $summary.Trim() }
            if (@(Get-ChildItem (Join-Path $repo 'tests\integration') -Recurse -Filter 'test_*.gd' -ErrorAction SilentlyContinue).Count -eq 0) {
                Add-Result SKIPPED 'suite integration' 'no integration tests yet'
            }
            else { Invoke-Suite -ProjectPath $root -SuiteDir 'integration' -Name 'integration' }
        }
    }
}
Complete-Run -Title 'test' -ReportPath (Join-Path $reports "test-$Suite.json")
