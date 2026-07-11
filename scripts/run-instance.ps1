<#
.SYNOPSIS
  Launch an on-demand, isolated Listenarr TEST instance (DEV or VERIFY).

  This is the "not-a-wrapper" wrapper: it changes NO source code. It only sets two env vars
  (LISTENARR_CONTENT_ROOT + ASPNETCORE_URLS) and runs the app that already exists, so each instance
  uses its own data dir + port. LIVE (C:\ProgramData\Listenarr, service, port 4545) is never touched.

  Layout (container = the folder holding _DevFork/_Upstream):
    Dev    -> tree _DevFork  (canary),          data _DevData,      port 4546
    Verify -> tree _Upstream (upstream-canary), data _UpstreamData, port 4547

.PARAMETER Role        Dev | Verify
.PARAMETER Branch      (Verify only) git switch the _Upstream worktree to this branch first.
.PARAMETER BackendOnly Skip the frontend build; run the API only (fine for backend / behaviour fixes).

.EXAMPLE  .\run-instance.ps1 -Role Dev -BackendOnly
.EXAMPLE  .\run-instance.ps1 -Role Verify -Branch fix/foo
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Dev','Verify')][string]$Role,
    [string]$Branch,
    [switch]$BackendOnly,
    [switch]$NoBrowser,
    # Run the API as a Release build for production-representative performance testing (default Debug).
    [switch]$Release
)
$ErrorActionPreference = 'Stop'

# ...\_DevFork\scripts -> _DevFork -> container root (holds _DevFork/_Upstream/_DevData/_UpstreamData)
$container = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

$map = @{
    Dev    = @{ Tree = '_DevFork';  Data = '_DevData';      Port = 4546 }
    Verify = @{ Tree = '_Upstream'; Data = '_UpstreamData'; Port = 4547 }
}[$Role]

$tree = Join-Path $container $map.Tree
$data = Join-Path $container $map.Data
$port = $map.Port
$api  = Join-Path $tree 'listenarr.api'

if (-not (Test-Path $api)) { throw "API project not found: $api (is the '$($map.Tree)' worktree present?)" }

# Safety: never let a test instance collide with the LIVE port.
if ($port -eq 4545) { throw "Refusing: port 4545 is LIVE." }

# Verify: point the _Upstream worktree at the branch under test.
if ($Role -eq 'Verify' -and $Branch) {
    Write-Host "[run-instance] switching _Upstream -> '$Branch'"
    git -C $tree switch $Branch
    if ($LASTEXITCODE -ne 0) { throw "git switch '$Branch' failed in $tree" }
}

New-Item -ItemType Directory -Force -Path $data | Out-Null

# Frontend (only when UI testing). Backend/behaviour fixes should use -BackendOnly.
# NOTE (2026-07-08): backend path is verified; this FE path mirrors update-from-upstream.ps1 but is
# not yet smoke-tested end-to-end.
if (-not $BackendOnly) {
    $fe = Join-Path $tree 'fe'
    Write-Host "[run-instance] building frontend ($fe)"
    Push-Location $fe
    try {
        if (-not (Test-Path (Join-Path $fe 'node_modules'))) {
            Write-Host "[run-instance] npm ci ..."
            npm ci
            if ($LASTEXITCODE -ne 0) { throw "npm ci failed" }
        }
        # Rolldown win32-x64 native-binding workaround (npm/cli#4828): npm ci silently skips the optional
        # binding, so `npm run build` throws "Cannot find module './rolldown-binding.win32-x64-msvc.node'".
        # Reinstall it version-matched with --force, but ONLY when the .node is actually missing (fast on
        # repeat runs). Mirrors update-from-upstream.ps1.
        $bindingDir = Join-Path $fe 'node_modules\@rolldown\binding-win32-x64-msvc'
        if (-not (Get-ChildItem -Path $bindingDir -Filter *.node -ErrorAction SilentlyContinue)) {
            $rolldownPkg = Join-Path $fe 'node_modules\rolldown\package.json'
            if (Test-Path $rolldownPkg) {
                $rolldownVer = (Get-Content $rolldownPkg -Raw | ConvertFrom-Json).version
                Write-Host "[run-instance] restoring rolldown win32-x64 binding @ $rolldownVer ..."
                npm install "@rolldown/binding-win32-x64-msvc@$rolldownVer" --no-save --force
                if ($LASTEXITCODE -ne 0) { Write-Warning "binding reinstall returned non-zero; build may fail" }
            }
        } else {
            Write-Host "[run-instance] rolldown binding already present."
        }
        Write-Host "[run-instance] npm run build ..."
        npm run build
        if ($LASTEXITCODE -ne 0) { throw "frontend build failed" }
    } finally { Pop-Location }
    # Serve the freshly built SPA from THIS instance's web root (content-root\wwwroot).
    robocopy (Join-Path $fe 'dist') (Join-Path $data 'wwwroot') /MIR /NFL /NDL /NP /R:1 /W:1 | Out-Null
}

# The whole isolation mechanism: two env vars. No code changes.
$env:LISTENARR_CONTENT_ROOT = $data
$env:ASPNETCORE_URLS        = "http://localhost:$port"
# Enable the sideloaded AI debug log sink (POST /ai-log -> <data>\ai-debug-log.jsonl). Test instances only;
# inert on LIVE. See listenarr.api/DevTools/AiDebugLogMiddleware.cs.
$env:LISTENARR_AI_LOG       = '1'

$branchNow = (git -C $tree branch --show-current 2>$null)
Write-Host ""
Write-Host "==================== Listenarr TEST instance: $Role ====================" -ForegroundColor Cyan
Write-Host " Source tree : $tree   [branch: $branchNow]"
Write-Host " Data root   : $data"
Write-Host " Database    : $data\config\database\listenarr.db"
Write-Host " URL         : http://localhost:$port"
Write-Host " LIVE is     : http://localhost:4545  (this is NOT live)"
Write-Host " Stop        : Ctrl+C  (frees RAM)"
Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host ""

# Start the app as a child process so we can open a browser once it's listening and clean BOTH up on stop.
# --no-launch-profile so launchSettings.json can't override our URL/env.
Write-Host "[run-instance] starting app (first build may take a few minutes)..."
$config = if ($Release) { 'Release' } else { 'Debug' }
Write-Host "[run-instance] API build configuration: $config"
$app = Start-Process dotnet -PassThru -NoNewWindow -ArgumentList @(
    'run', '--project', $api, '-c', $config, '--no-launch-profile')

try {
    # UI runs: open the DEFAULT browser on the instance once it's listening. Close that window/tab when done
    # to reclaim the frontend's RAM (this app leaks memory in the UI - especially on _Upstream / VERIFY,
    # which is raw upstream without our fixes). Tip: open it in a NEW window so closing it frees the most.
    if (-not $BackendOnly -and -not $NoBrowser) {
        Write-Host "[run-instance] waiting for http://localhost:$port ..."
        $up = $false
        for ($i = 0; $i -lt 150 -and -not $up; $i++) {
            if ($app.HasExited) { throw "app exited during startup (code $($app.ExitCode)) - see log above" }
            try { $t = [Net.Sockets.TcpClient]::new(); $t.Connect('localhost', $port); $up = $t.Connected; $t.Close() }
            catch { Start-Sleep -Seconds 2 }
        }
        if ($up) {
            Start-Process "http://localhost:$port"   # default browser
            Write-Host "[run-instance] opened default browser -> CLOSE that window/tab when done to free its RAM."
        } else {
            Write-Host "[run-instance] app not listening after wait; open http://localhost:$port manually."
        }
    }
    Wait-Process -Id $app.Id
} finally {
    Write-Host ""
    Write-Host "[run-instance] stopping app. (Close the browser window yourself to free its RAM.)"
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
    Write-Host "[run-instance] stopped."
}
