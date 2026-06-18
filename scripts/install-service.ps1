# Listenarr Windows Service installer
# Usage:
#   .\install-service.ps1 install [-ExePath <path>] [-ServiceName <name>]
#   .\install-service.ps1 uninstall [-ServiceName <name>]
#   .\install-service.ps1 status [-ServiceName <name>]
#
# Requires: elevated (Run as Administrator)

param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('install', 'uninstall', 'status')]
    [string]$Action,

    [string]$ExePath,
    [string]$ServiceName = 'Listenarr',
    [string]$DisplayName = 'Listenarr Audiobook Manager'
)

$ErrorActionPreference = 'Stop'

# Check for elevation
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

function Install-ListenarrService {
    if (-not $ExePath) {
        # Default: look for Listenarr.Api.exe next to this script's parent dir
        $candidate = Join-Path (Split-Path $PSScriptRoot) 'Listenarr.Api.exe'
        if (Test-Path $candidate) {
            $ExePath = $candidate
        } else {
            Write-Error "ExePath not specified and Listenarr.Api.exe not found at $candidate"
            exit 1
        }
    }

    $ExePath = (Resolve-Path $ExePath).Path

    if (-not (Test-Path $ExePath)) {
        Write-Error "Executable not found: $ExePath"
        exit 1
    }

    # Check if service already exists
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warning "Service '$ServiceName' already exists (Status: $($existing.Status)). Uninstall first or use a different name."
        exit 1
    }

    Write-Host "Creating service '$ServiceName'..." -ForegroundColor Cyan
    sc.exe create $ServiceName binPath= "`"$ExePath`"" start= delayed-auto DisplayName= "`"$DisplayName`""
    if ($LASTEXITCODE -ne 0) { Write-Error "sc create failed (exit $LASTEXITCODE)"; exit 1 }

    Write-Host "Setting recovery options (restart on failure)..." -ForegroundColor Cyan
    sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000
    if ($LASTEXITCODE -ne 0) { Write-Warning "sc failure configuration failed - service created but recovery not set" }

    Write-Host "Setting service description..." -ForegroundColor Cyan
    sc.exe description $ServiceName "Listenarr audiobook management and automation service"

    Write-Host ""
    Write-Host "Service '$ServiceName' installed successfully." -ForegroundColor Green
    Write-Host "  Exe:  $ExePath" -ForegroundColor Gray
    Write-Host "  Start: sc start $ServiceName" -ForegroundColor Gray
    Write-Host "  URL:  http://localhost:4545" -ForegroundColor Gray
}

function Uninstall-ListenarrService {
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Warning "Service '$ServiceName' not found."
        exit 0
    }

    if ($existing.Status -ne 'Stopped') {
        Write-Host "Stopping service '$ServiceName'..." -ForegroundColor Cyan
        sc.exe stop $ServiceName | Out-Null
        # Wait for stop (up to 30s)
        $timeout = (Get-Date).AddSeconds(30)
        while ((Get-Service -Name $ServiceName).Status -ne 'Stopped' -and (Get-Date) -lt $timeout) {
            Start-Sleep -Milliseconds 500
        }
    }

    Write-Host "Deleting service '$ServiceName'..." -ForegroundColor Cyan
    sc.exe delete $ServiceName
    if ($LASTEXITCODE -ne 0) { Write-Error "sc delete failed (exit $LASTEXITCODE)"; exit 1 }

    Write-Host "Service '$ServiceName' removed." -ForegroundColor Green
}

function Get-ListenarrServiceStatus {
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "Service '$ServiceName' is not installed." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "Service: $ServiceName" -ForegroundColor Cyan
    Write-Host "  Status:  $($existing.Status)"
    Write-Host "  Startup: $($existing.StartType)"

    $imagePath = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -ErrorAction SilentlyContinue).ImagePath
    if ($imagePath) {
        Write-Host "  ExePath: $imagePath"
    }
}

switch ($Action) {
    'install'   { Install-ListenarrService }
    'uninstall' { Uninstall-ListenarrService }
    'status'    { Get-ListenarrServiceStatus }
}
