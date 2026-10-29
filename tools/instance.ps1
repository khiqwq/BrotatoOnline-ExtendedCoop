<#
.SYNOPSIS
  Development helper: create and run isolated game instances for M1 probes.
  An instance mirrors the Steam layout under .local/instances/<Name>/:
    steamapps/common/Brotato/   engine copy, steam_appid.txt, steam_data.json, DLC pck
    steamapps/workshop/content/1942280/<item>/   copies of workshop zips
  It reads the original Brotato.pck through --main-pack and keeps user:// in
  .local/userdata/instance-<Name>/. The Steam build's Mod Loader only loads zips
  from workshop item folders the account is subscribed to, so the development
  build of this extension is side-loaded next to the (byte-identical) Brotato
  Online zip in that item's instance folder. Nothing is written into the real
  game or workshop folders and the player's real saves are never touched.
  See docs/runbooks/isolated-game-instance.md.
.EXAMPLE
  pwsh ./tools/instance.ps1 -Action New -Name probe -Mods BrotatoOnline,Extension -WithDlc
  pwsh ./tools/instance.ps1 -Action Start -Name probe -StopAfterSec 60
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('New', 'Start', 'Stop', 'Remove', 'Status')][string]$Action,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,32}$')][string]$Name,
    [string[]]$Mods = @('BrotatoOnline', 'Extension'),
    [switch]$WithDlc,
    [switch]$DevBuild,
    [switch]$ShowWindow,
    [int]$StopAfterSec = 0,
    [string[]]$ExtraArgs = @()
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force

# pwsh -File passes "a,b" as one string; accept both forms.
$Mods = @($Mods | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
foreach ($m in $Mods) { if ($m -notin 'BrotatoOnline', 'Extension', 'MouseUI') { throw "unknown mod '$m' (BrotatoOnline, Extension, MouseUI)" } }
$ExtraArgs = @($ExtraArgs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$cfg = Read-LocalConfig
if (-not $cfg) { throw 'run tools/setup.ps1 first' }
$lock = Read-Lock
$instRoot = Get-LocalDir "instances\$Name"
$instDir = Join-Path $instRoot 'steamapps\common\Brotato'
$workshopDir = Join-Path $instRoot "steamapps\workshop\content\$((Read-Lock).game.app_id)"
$userData = Get-LocalDir "userdata\instance-$Name"
$pidFile = Join-Path $instRoot 'instance.pid'

function Stop-Instance {
    if (-not (Test-Path $pidFile)) { return $false }
    $procId = [int](Get-Content $pidFile)
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p -and $p.Path -and ((Resolve-Path $p.Path).Path -eq (Resolve-Path (Join-Path $instDir 'Brotato.exe')).Path)) {
        $p.Kill($true); $p.WaitForExit(10000) | Out-Null
    }
    Remove-Item $pidFile -Force
    return $true
}

switch ($Action) {
    'New' {
        if (Test-Path $instRoot) { Stop-Instance | Out-Null; Remove-Item -Recurse -Force $instRoot }
        New-Item -ItemType Directory -Force $instDir, $workshopDir | Out-Null
        foreach ($f in 'Brotato.exe', 'steam_api64.dll', 'steam_data.json') { Copy-Item (Join-Path $cfg.game_path $f) $instDir }
        # Present steam_appid.txt keeps Steam from relaunching the installed game
        # (singletons/platforms/steam.gd calls restartAppIfNecessary).
        Set-Content -NoNewline -Encoding ascii (Join-Path $instDir 'steam_appid.txt') "$($lock.game.app_id)"
        if ($WithDlc) {
            foreach ($d in $lock.dlc) {
                $src = Join-Path $cfg.game_path $d.file
                if (Test-Path $src) { Copy-Item $src $instDir }
            }
        }
        $bo = $lock.upstream_mods | Where-Object id -eq 'six666-BrotatoOnline'
        $mouse = $lock.upstream_mods | Where-Object id -eq 'CoopFix-OnlineMouseUI'
        foreach ($m in $Mods) {
            switch ($m) {
                'BrotatoOnline' {
                    $d = Join-Path $workshopDir $bo.workshop_id
                    New-Item -ItemType Directory -Force $d | Out-Null
                    Copy-Item $cfg.upstream.'six666-BrotatoOnline'.zip $d
                    if ((Get-FileSha256 (Join-Path $d $bo.zip)) -ne $bo.zip_sha256) { throw 'Brotato Online zip copy differs from lock' }
                }
                'MouseUI' {
                    $d = Join-Path $workshopDir $mouse.workshop_id
                    New-Item -ItemType Directory -Force $d | Out-Null
                    Copy-Item $cfg.upstream.'CoopFix-OnlineMouseUI'.zip $d
                }
                'Extension' {
                    if ($Mods -notcontains 'BrotatoOnline') { throw 'Extension is side-loaded in the Brotato Online item folder; include BrotatoOnline' }
                    $d = Join-Path $workshopDir $bo.workshop_id
                    New-Item -ItemType Directory -Force $d | Out-Null
                    $files = Get-PackageFileList -IncludeDebug:$DevBuild
                    $sha = New-DeterministicZip -RelativePaths $files -OutPath (Join-Path $d "$($lock.extension.id).zip")
                    Write-Host "extension zip $sha ($($files.Count) files, dev=$([bool]$DevBuild))"
                }
            }
        }
        Write-Host "instance $Name ready at $instRoot"
    }
    'Start' {
        if (-not (Test-Path (Join-Path $instDir 'Brotato.exe'))) { throw "instance $Name missing; use -Action New" }
        if (Test-Path $pidFile) { throw "instance $Name already running (pid $(Get-Content $pidFile))" }
        New-Item -ItemType Directory -Force $userData | Out-Null
        $psi = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $instDir 'Brotato.exe'))
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $instDir
        $psi.Environment['APPDATA'] = (Resolve-Path $userData).Path
        $psi.Environment.Remove('XDG_CONFIG_HOME') | Out-Null
        $argv = @('--main-pack', (Join-Path $cfg.game_path 'Brotato.pck'))
        if (-not $ShowWindow) { $argv += '--no-window' }
        foreach ($a in $argv + $ExtraArgs) { $psi.ArgumentList.Add($a) }
        $p = [System.Diagnostics.Process]::Start($psi)
        Set-Content $pidFile $p.Id
        $outLog = Join-Path $instRoot 'stdout.log'
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        Write-Host "started $Name pid $($p.Id); user data $userData"
        if ($StopAfterSec -gt 0) {
            $exited = $p.WaitForExit($StopAfterSec * 1000)
            if (-not $exited) { $p.Kill($true); $p.WaitForExit() }
            Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
            Set-Content -Encoding utf8 $outLog ($outTask.Result + $errTask.Result)
            Write-Host "stopped $Name (exited by itself: $exited, code $($p.ExitCode)); output in $outLog"
        }
        else {
            Write-Host "running in background; stop with -Action Stop (output is not captured for background runs; see user://logs)"
        }
    }
    'Stop' { if (Stop-Instance) { Write-Host "stopped $Name" } else { Write-Host "$Name not running" } }
    'Status' {
        $running = (Test-Path $pidFile) -and (Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue)
        Write-Host "instance $Name dir=$instRoot exists=$(Test-Path $instRoot) running=$([bool]$running) userdata=$userData"
    }
    'Remove' {
        Stop-Instance | Out-Null
        foreach ($d in $instRoot, $userData) { if (Test-Path $d) { Remove-Item -Recurse -Force $d } }
        Write-Host "removed $Name"
    }
}
