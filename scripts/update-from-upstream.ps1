<#
.SYNOPSIS
    One-command Listenarr fork updater: rebase your Windows patch onto upstream,
    build a win-x64 self-contained release, and hot-swap the running service.

.DESCRIPTION
    Your fork (origin) = upstream/canary + a small Windows-Service patch. This script
    automates the whole update loop so you never juggle files by hand:

        fetch upstream -> rebase your patch -> build FE+BE -> backup bin -> swap -> verify -> push

    Data safety: the live SQLite DB and config live UNDER bin\ at
    C:\ProgramData\Listenarr\bin\config\ (database\listenarr.db, config.json,
    appsettings\). The swap mirrors the new build into bin\ but EXCLUDES bin\config\
    (robocopy /XD), so your library and settings are never touched. The service is
    stopped first (clean DB), a full timestamped backup of bin\ (including config\) is
    taken, and if the new build fails to start it is auto-restored.

.PARAMETER Ref
    Upstream ref to rebase onto. Default: upstream/canary.

.PARAMETER SkipRebase
    Skip fetch+rebase; build and deploy the current working tree as-is.

.PARAMETER SkipBuild
    Skip FE/BE build; redeploy whatever is already staged (rarely needed).

.PARAMETER NoPush
    Do not push the rebased branch to origin after a successful update.

.PARAMETER ServiceName
    Windows service name. Default: Listenarr.

.PARAMETER InstallRoot
    Install root. Default: C:\ProgramData\Listenarr (bin\ swapped, config\ preserved).

.PARAMETER HealthUrl
    URL polled to confirm the service came up. Default: http://localhost:4545

.EXAMPLE
    # Elevated PowerShell:
    .\scripts\update-from-upstream.ps1

.EXAMPLE
    .\scripts\update-from-upstream.ps1 -NoPush        # update but don't push the rebase
    .\scripts\update-from-upstream.ps1 -SkipRebase    # rebuild+redeploy current tree
#>
[CmdletBinding()]
param(
    [string]$Ref          = 'upstream/canary',
    [switch]$SkipRebase,
    [switch]$SkipBuild,
    [switch]$NoPush,
    [string]$ServiceName  = 'Listenarr',
    [string]$InstallRoot  = 'C:\ProgramData\Listenarr',
    [string]$HealthUrl    = 'http://localhost:4545',
    [int]$KeepBackups     = 3
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Paths ────────────────────────────────────────────────────────────────────
$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FrontendDir = Join-Path $RepoRoot 'fe'
$ApiProject = Join-Path $RepoRoot 'listenarr.api\Listenarr.Api.csproj'
$StageDir   = Join-Path $RepoRoot '.deploy-staging\win-x64'
$BinDir     = Join-Path $InstallRoot 'bin'
$ConfigDir  = Join-Path $BinDir 'config'      # live DB + settings; MUST survive the swap
$BackupRoot = "$InstallRoot.backups"

# ── Console helpers ──────────────────────────────────────────────────────────
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Info($m) { Write-Host "    $m" -ForegroundColor Gray }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }
function Die($m)  { Write-Error $m; exit 1 }

# robocopy returns 0-7 on success (bit flags); 8+ is a real failure.
function Invoke-Robocopy([string]$Src, [string]$Dst, [string[]]$ExtraArgs) {
    $roboArgs = @($Src, $Dst) + $ExtraArgs
    & robocopy.exe @roboArgs | Out-Null
    if ($LASTEXITCODE -ge 8) { Die "robocopy '$Src' -> '$Dst' failed (exit $LASTEXITCODE)." }
    $global:LASTEXITCODE = 0
}

# ── 0. Preflight ─────────────────────────────────────────────────────────────
Step 'Preflight'

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Die 'Must run elevated (Run as Administrator) to stop/start the service.' }

Push-Location $RepoRoot
try {
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
    Info "Repo:   $RepoRoot"
    Info "Branch: $branch"
    if ($branch -ne 'canary') { Warn "Not on 'canary' (on '$branch'). Continuing, but the rebase targets $Ref." }

    $dirty = (git status --porcelain)
    if ($dirty -and -not $SkipRebase) {
        Die "Working tree is dirty. Commit or stash before rebasing:`n$dirty"
    }

    # ── 1. Fetch + rebase ────────────────────────────────────────────────────
    if (-not $SkipRebase) {
        Step "Rebase onto $Ref"
        git fetch upstream --prune
        if ($LASTEXITCODE -ne 0) { Die 'git fetch upstream failed.' }

        $before = (git rev-parse HEAD).Trim()
        git rebase $Ref
        if ($LASTEXITCODE -ne 0) {
            Warn 'Rebase hit a conflict. Aborting to leave the repo clean.'
            git rebase --abort | Out-Null
            $msg = @"
Rebase onto $Ref conflicts with your local patch. Resolve manually:
    git rebase $Ref     (fix conflicts, then: git rebase --continue)
then re-run with -SkipRebase.
"@
            Die $msg
        }
        $after = (git rev-parse HEAD).Trim()
        if ($before -eq $after) { Ok "Already up to date with $Ref." }
        else { Ok "Rebased: $($before.Substring(0,8)) -> $($after.Substring(0,8))" }
    } else {
        Warn 'SkipRebase: building the current working tree as-is.'
    }

    # ── 2 + 3. Build frontend + backend ──────────────────────────────────────
    if (-not $SkipBuild) {
        Step 'Build frontend (fe)'
        Push-Location $FrontendDir
        try {
            Info 'npm ci ...'
            npm ci
            if ($LASTEXITCODE -ne 0) { Die 'npm ci failed.' }

            # Rolldown native-binding workaround (npm/cli#4828): npm ci silently
            # skips the win32-x64 optional binding. Reinstall it matching the
            # installed rolldown version, or `npm run build` throws
            # "Cannot find module './rolldown-binding.win32-x64-msvc.node'".
            $rolldownPkg = Join-Path $FrontendDir 'node_modules\rolldown\package.json'
            if (Test-Path $rolldownPkg) {
                $rolldownVer = (Get-Content $rolldownPkg -Raw | ConvertFrom-Json).version
                Info "Restoring rolldown win32-x64 binding @ $rolldownVer ..."
                npm install "@rolldown/binding-win32-x64-msvc@$rolldownVer" --no-save --force
                if ($LASTEXITCODE -ne 0) { Warn 'Binding reinstall returned non-zero; build may still fail.' }
            } else {
                Warn 'rolldown not found under node_modules; skipping binding fix.'
            }

            Info 'npm run build ...'
            npm run build
            if ($LASTEXITCODE -ne 0) { Die 'Frontend build (npm run build) failed.' }
        } finally { Pop-Location }

        Step 'Publish backend (win-x64, self-contained)'
        if (Test-Path $StageDir) { Remove-Item $StageDir -Recurse -Force }
        # SkipFrontendBuild=true bypasses the csproj npm ci (which would re-break the
        # binding); we copy fe\dist into wwwroot ourselves below.
        dotnet publish $ApiProject -c Release -r win-x64 --self-contained true `
            /p:PublishSingleFile=true /p:SkipFrontendBuild=true -o $StageDir
        if ($LASTEXITCODE -ne 0) { Die 'dotnet publish failed.' }

        Step 'Copy frontend dist into wwwroot'
        $dist = Join-Path $FrontendDir 'dist'
        if (-not (Test-Path $dist)) { Die "Frontend dist not found at $dist." }
        Invoke-Robocopy $dist (Join-Path $StageDir 'wwwroot') @('/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
        Ok 'wwwroot populated.'
    } else {
        Warn 'SkipBuild: using existing staged output.'
    }

    $stagedExe = Join-Path $StageDir 'Listenarr.Api.exe'
    if (-not (Test-Path $stagedExe)) { Die "Staged build missing $stagedExe. Run without -SkipBuild." }

    # ── 4. Stop the service (quiesce the DB before backup/swap) ──────────────
    Step 'Stop service'
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { Die "Service '$ServiceName' is not installed. Run scripts\install-service.ps1 install first." }
    if ($svc.Status -ne 'Stopped') {
        Info "Stopping '$ServiceName' ..."
        Stop-Service -Name $ServiceName -Force
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    Ok 'Service stopped.'

    # ── 5. Backup current bin (now quiescent, includes config\ + DB) ─────────
    Step 'Backup current bin'
    $backupDir = $null
    if (Test-Path $BinDir) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $backupDir = Join-Path $BackupRoot $stamp
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Invoke-Robocopy $BinDir (Join-Path $backupDir 'bin') @('/E', '/MT:8', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
        Ok "Backed up bin (incl. config\ DB) -> $backupDir"

        # Rotate: keep the newest N.
        Get-ChildItem $BackupRoot -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
            Sort-Object Name -Descending | Select-Object -Skip $KeepBackups | ForEach-Object {
                Info "Pruning old backup $($_.Name)"; Remove-Item $_.FullName -Recurse -Force
            }
    } else {
        Warn "No existing bin at $BinDir (fresh install)."
    }

    # ── 6. Swap bin, preserving bin\config\ (live DB + settings) ─────────────
    Step 'Swap bin (preserving config\)'
    # /MIR mirrors staging into bin (purging stale old binaries), but /XD excludes
    # bin\config\ entirely — so the live listenarr.db, config.json and appsettings
    # are neither overwritten nor deleted.
    Invoke-Robocopy $StageDir $BinDir @('/MIR', '/XD', $ConfigDir, '/MT:8', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    Ok 'bin swapped; config\ preserved.'

    Step 'Start service and verify'
    Start-Service -Name $ServiceName

    $running = $false
    try {
        (Get-Service $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
        $running = $true
    } catch { $running = $false }

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
        if ($backupDir) {
            Step 'Auto-rollback'
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            (Get-Service $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
            Invoke-Robocopy (Join-Path $backupDir 'bin') $BinDir @('/MIR', '/MT:8', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
            Start-Service -Name $ServiceName
            Die "Rolled back to previous bin from $backupDir. New build left staged at $StageDir for inspection."
        }
        Die "Service unhealthy and no backup available to roll back to. Check Event Viewer / logs."
    }

    $ver = (Get-Item $stagedExe).VersionInfo.FileVersion
    Ok "Listenarr $ver is running at $HealthUrl"

    # ── 6. Push ──────────────────────────────────────────────────────────────
    if (-not $SkipRebase -and -not $NoPush) {
        Step 'Push rebased branch to origin'
        git push origin HEAD
        if ($LASTEXITCODE -ne 0) {
            Warn 'Push failed (likely non-fast-forward after rebase).'
            Warn 'Review, then: git push --force-with-lease origin HEAD'
        } else { Ok 'Pushed to origin.' }
    } elseif ($NoPush) {
        Warn 'NoPush: rebased branch not pushed. Push manually when ready.'
    }

    Step 'Done'
    Ok 'Update complete.'
}
finally { Pop-Location }
