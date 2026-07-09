<#
.SYNOPSIS
    Fast targeted local deploy of the Listenarr fork: FE-only, BE-only, or Both.
    Companion to update-from-upstream.ps1 (which does the full fetch/rebase/deploy).
    This one is the daily iteration loop - no upstream fetch, no rebase, no push.

.DESCRIPTION
    -Target FE    Build the frontend and drop it straight into the LIVE service's
                  wwwroot. No stop, no backup, no publish, no restart - the running
                  service serves the new static files on the next request. Hard-refresh
                  the browser. Seconds. (Use this for TanStack / FE iteration.)
    -Target BE    dotnet publish (SkipFrontendBuild) -> stop -> backup -> swap bin
                  EXCLUDING config\ AND wwwroot\ (so the DB and current FE survive) ->
                  restart -> health-check, with auto-rollback on failure.
    -Target Both  Full build + swap (equivalent to update-from-upstream's deploy stage).

    Data safety: the live DB + settings under bin\config\ are never touched (robocopy /XD).
    For BE, the current wwwroot is also excluded from the mirror so the front end is kept.

.PARAMETER Target        FE | BE | Both. Default: Both.
.PARAMETER NoBackup      Skip the timestamped bin backup (BE/Both).
.PARAMETER ServiceName   Windows service name. Default: Listenarr.
.PARAMETER InstallRoot   Install root. Default: C:\ProgramData\Listenarr.
.PARAMETER HealthUrl     Health probe URL. Default: http://localhost:4545.

.EXAMPLE
    .\scripts\deploy.ps1 -Target FE      # fast: rebuild FE into the live service, no restart
.EXAMPLE
    .\scripts\deploy.ps1 -Target BE      # rebuild+swap backend only, keep current FE
.EXAMPLE
    .\scripts\deploy.ps1                 # -Target Both (full)
#>
[CmdletBinding()]
param(
    [ValidateSet('FE', 'BE', 'Both')][string]$Target = 'Both',
    [switch]$NoBackup,
    [switch]$CleanInstall,
    [string]$ServiceName = 'Listenarr',
    [string]$InstallRoot = 'C:\ProgramData\Listenarr',
    [string]$HealthUrl   = 'http://localhost:4545',
    [int]$KeepBackups    = 3
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Paths ────────────────────────────────────────────────────────────────────
$RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FrontendDir = Join-Path $RepoRoot 'fe'
$ApiProject  = Join-Path $RepoRoot 'listenarr.api\Listenarr.Api.csproj'
$StageDir    = Join-Path $RepoRoot '.deploy-staging\win-x64'
$BinDir      = Join-Path $InstallRoot 'bin'
$ConfigDir   = Join-Path $BinDir 'config'    # live DB + settings; MUST survive
$WwwRoot     = Join-Path $BinDir 'wwwroot'   # live front end
$BackupRoot  = "$InstallRoot.backups"

# ── Console helpers ──────────────────────────────────────────────────────────
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Info($m) { Write-Host "    $m" -ForegroundColor Gray }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }
function Die($m)  { Write-Error $m; exit 1 }

# robocopy returns 0-7 on success (bit flags); 8+ is a real failure.
function Invoke-Robocopy([string]$Src, [string]$Dst, [string[]]$ExtraArgs) {
    $ErrorActionPreference = 'Continue'   # native stderr must not terminate; we judge by exit code below.
    # /R:3 /W:1 caps robocopy's default retry (1,000,000 x 30s = an effective hang). The outer
    # loop retries the whole copy on a transient "serious error" (exit >=8) - e.g. the live
    # service holding a wwwroot file mid-serve while /MIR purges it. Such locks clear in ~a second.
    $roboArgs = @($Src, $Dst) + $ExtraArgs + @('/R:3', '/W:1')
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & robocopy.exe @roboArgs | Out-Null
        if ($LASTEXITCODE -lt 8) { $global:LASTEXITCODE = 0; return }
        Warn "robocopy '$Src' -> '$Dst' exit $LASTEXITCODE (attempt $attempt/3) - retrying..."
        Start-Sleep -Seconds 2
    }
    Die "robocopy '$Src' -> '$Dst' failed after 3 attempts (exit $LASTEXITCODE)."
}

# ── Build steps ──────────────────────────────────────────────────────────────
function Build-Frontend {
    $ErrorActionPreference = 'Continue'   # native (npm) stderr warnings must not terminate; judged by $LASTEXITCODE below.
    Step 'Build frontend (fe)'
    Push-Location $FrontendDir
    try {
        # Fast loop: skip the slow `npm ci` (wipes + reinstalls node_modules) when the tree is
        # already installed AND the rolldown win32 binding is present. -CleanInstall forces it.
        $nodeModules     = Join-Path $FrontendDir 'node_modules'
        $rolldownBinding = Join-Path $FrontendDir 'node_modules\@rolldown\binding-win32-x64-msvc'
        if ($CleanInstall -or -not (Test-Path $nodeModules) -or -not (Test-Path $rolldownBinding)) {
            Info 'npm ci ...'
            npm ci
            if ($LASTEXITCODE -ne 0) { Die 'npm ci failed.' }

            # Rolldown native-binding workaround (npm/cli#4828): npm ci silently skips the
            # win32-x64 optional binding; reinstall it matching the installed rolldown version
            # or `npm run build` throws "Cannot find module './rolldown-binding.win32-x64-msvc.node'".
            $rolldownPkg = Join-Path $FrontendDir 'node_modules\rolldown\package.json'
            if (Test-Path $rolldownPkg) {
                $rolldownVer = (Get-Content $rolldownPkg -Raw | ConvertFrom-Json).version
                Info "Restoring rolldown win32-x64 binding @ $rolldownVer ..."
                npm install "@rolldown/binding-win32-x64-msvc@$rolldownVer" --no-save --force
                if ($LASTEXITCODE -ne 0) { Warn 'Binding reinstall returned non-zero; build may still fail.' }
            } else {
                Warn 'rolldown not found under node_modules; skipping binding fix.'
            }
        } else {
            Info 'node_modules + rolldown binding present - skipping npm ci (use -CleanInstall to force).'
        }

        Info 'npm run build ...'
        npm run build
        if ($LASTEXITCODE -ne 0) { Die 'Frontend build (npm run build) failed.' }
    } finally { Pop-Location }

    $dist = Join-Path $FrontendDir 'dist'
    if (-not (Test-Path $dist)) { Die "Frontend dist not found at $dist." }
    return $dist
}

function Publish-Backend {
    $ErrorActionPreference = 'Continue'   # native (dotnet) stderr warnings must not terminate; judged by $LASTEXITCODE below.
    Step 'Publish backend (win-x64, self-contained)'
    if (Test-Path $StageDir) { Remove-Item $StageDir -Recurse -Force }
    # SkipFrontendBuild=true bypasses the csproj npm ci (which would re-break the binding);
    # the frontend is copied into wwwroot separately.
    dotnet publish $ApiProject -c Release -r win-x64 --self-contained true `
        /p:PublishSingleFile=true /p:SkipFrontendBuild=true -o $StageDir
    if ($LASTEXITCODE -ne 0) { Die 'dotnet publish failed.' }
    $stagedExe = Join-Path $StageDir 'Listenarr.Api.exe'
    if (-not (Test-Path $stagedExe)) { Die "Staged build missing $stagedExe." }
    return $stagedExe
}

# ── Service ops ──────────────────────────────────────────────────────────────
function Stop-Svc {
    Step 'Stop service'
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { Die "Service '$ServiceName' is not installed." }
    if ($svc.Status -ne 'Stopped') {
        Info "Stopping '$ServiceName' ..."
        Stop-Service -Name $ServiceName -Force
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    Ok 'Service stopped.'
}

function Backup-Bin {
    if ($NoBackup) { Warn 'NoBackup: skipping bin backup.'; return $null }
    Step 'Backup current bin'
    if (-not (Test-Path $BinDir)) { Warn "No existing bin at $BinDir."; return $null }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $backupDir = Join-Path $BackupRoot $stamp
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Invoke-Robocopy $BinDir (Join-Path $backupDir 'bin') @('/E', '/MT:8', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    Ok "Backed up bin (incl. config\ DB) -> $backupDir"
    Get-ChildItem $BackupRoot -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
        Sort-Object Name -Descending | Select-Object -Skip $KeepBackups | ForEach-Object {
            Info "Pruning old backup $($_.Name)"; Remove-Item $_.FullName -Recurse -Force
        }
    return $backupDir
}

function Start-And-Verify([string]$BackupDir, [string]$StagedExe) {
    Step 'Start service and verify'
    Start-Service -Name $ServiceName

    $running = $false
    try { (Get-Service $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(60)); $running = $true }
    catch { $running = $false }

    $healthy = $false
    if ($running) {
        Info "Service RUNNING. Probing $HealthUrl ..."
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            try {
                $r = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 5
                if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { $healthy = $true; break }
            } catch { Start-Sleep -Seconds 2 }
        }
    }

    if (-not ($running -and $healthy)) {
        Warn "New build did not come up healthy (running=$running, healthy=$healthy)."
        if ($BackupDir) {
            Step 'Auto-rollback'
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            (Get-Service $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
            Invoke-Robocopy (Join-Path $BackupDir 'bin') $BinDir @('/MIR', '/MT:8', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
            Start-Service -Name $ServiceName
            Die "Rolled back to previous bin from $BackupDir. New build left staged at $StageDir."
        }
        Die 'Service unhealthy and no backup to roll back to. Check Event Viewer / logs.'
    }

    if ($StagedExe) { $ver = (Get-Item $StagedExe).VersionInfo.FileVersion; Ok "Listenarr $ver is running at $HealthUrl" }
    else { Ok "Service healthy at $HealthUrl" }
}

# ── Preflight ────────────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Die 'Must run elevated (Run as Administrator) to write bin\ and control the service.' }

Push-Location $RepoRoot
try {
    Step "Deploy target: $Target"

    switch ($Target) {
        'FE' {
            $dist = Build-Frontend
            Stop-Svc   # the running service locks wwwroot files it is serving - stop before mirroring.
            Step 'Deploy frontend into wwwroot'
            Invoke-Robocopy $dist $WwwRoot @('/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
            Ok "FE deployed -> $WwwRoot"
            Start-And-Verify $null $null
        }

        'BE' {
            $exe = Publish-Backend
            Stop-Svc
            $backupDir = Backup-Bin
            Step 'Swap bin (preserving config\ AND wwwroot\)'
            # /MIR would purge dest files missing from the BE-only stage (which has no
            # wwwroot) - so /XD excludes BOTH config\ (DB) and wwwroot\ (current FE).
            Invoke-Robocopy $StageDir $BinDir @('/MIR', '/XD', $ConfigDir, $WwwRoot, '/MT:8', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
            Ok 'bin swapped; config\ + wwwroot\ preserved.'
            Start-And-Verify $backupDir $exe
        }

        'Both' {
            $dist = Build-Frontend
            $exe  = Publish-Backend
            Step 'Copy frontend dist into staged wwwroot'
            Invoke-Robocopy $dist (Join-Path $StageDir 'wwwroot') @('/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
            Ok 'staged wwwroot populated.'
            Stop-Svc
            $backupDir = Backup-Bin
            Step 'Swap bin (preserving config\)'
            Invoke-Robocopy $StageDir $BinDir @('/MIR', '/XD', $ConfigDir, '/MT:8', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
            Ok 'bin swapped; config\ preserved.'
            Start-And-Verify $backupDir $exe
        }
    }

    Step 'Done'
    Ok "Deploy ($Target) complete."
}
finally { Pop-Location }
