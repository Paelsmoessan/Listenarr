<#
.SYNOPSIS
  Seed a test instance (Dev/Verify) from the golden snapshot: a fresh, disposable DB carrying LIVE's full
  config + library, re-pointed to the library COPY so the instance can NEVER touch the real library.

  Option B: LIVE's DataProtection keys are NOT copied, so encrypted secrets (indexer / download-client API
  keys, tokens) won't decrypt on this instance - those won't authenticate, but every other setting and the
  whole library populate. All Settings-UI values come from the DB's ApplicationSettings row (in the snapshot),
  so we do NOT copy appsettings.json/config.json (avoids a port/auth collision; the app writes safe defaults).

  STOP the instance before running - its DB must be closed.

.PARAMETER Role         Dev | Verify
.PARAMETER RealLibrary  The real library root stored in the snapshot (default M:\Audiobooks).
.PARAMETER LibraryCopy  The safe copy the instance should point at (default M:\Audiobooks-DevLib).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Dev','Verify')][string]$Role,
    [string]$RealLibrary = 'M:\Audiobooks',
    [string]$LibraryCopy = 'M:\Audiobooks-DevLib'
)
$ErrorActionPreference = 'Stop'
$sqlite    = 'C:\sqlite\sqlite3.exe'
$container = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$golden    = Join-Path $container '_GoldenSnapshot\listenarr.db'
$dataName  = if ($Role -eq 'Dev') { '_DevData' } else { '_UpstreamData' }
$data      = Join-Path $container $dataName
$port      = if ($Role -eq 'Dev') { 4546 } else { 4547 }

if (-not (Test-Path $sqlite)) { throw "sqlite3 not found at $sqlite" }
if (-not (Test-Path $golden)) { throw "golden snapshot missing: $golden - run snapshot-live-db.ps1 first" }
if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
    throw "the $Role instance (port $port) is running - stop it first (its DB is open)."
}

# 1. Fresh disposable DB from the golden snapshot (wipe any old db + wal/shm first).
$dbDir = Join-Path $data 'config\database'
New-Item -ItemType Directory -Force -Path $dbDir | Out-Null
Get-ChildItem $dbDir -Filter 'listenarr.db*' -ErrorAction SilentlyContinue | Remove-Item -Force
$db = Join-Path $dbDir 'listenarr.db'
Copy-Item $golden $db -Force
Write-Host "[seed] $Role DB seeded from golden -> $db"

# 2. Re-point the library REAL -> COPY (RootFolders + absolute AudiobookFiles.Path) so the instance can
#    never mutate real files. SQLite: backslash is a literal (not an escape); '' would escape a quote.
$sql = @"
UPDATE RootFolders SET Path='$LibraryCopy' WHERE Path='$RealLibrary';
UPDATE AudiobookFiles SET Path=REPLACE(Path,'$RealLibrary\','$LibraryCopy\') WHERE Path LIKE '$RealLibrary\%';
"@
& $sqlite $db $sql
if ($LASTEXITCODE -ne 0) { throw "library re-point failed" }

$rf       = (& $sqlite -readonly $db "SELECT group_concat(Path,'; ') FROM RootFolders;")
$leftover = (& $sqlite -readonly $db "SELECT count(*) FROM AudiobookFiles WHERE Path LIKE '$RealLibrary\%';")
$books    = (& $sqlite -readonly $db "SELECT count(*) FROM Audiobooks;")
Write-Host "[seed] RootFolder(s): $rf"
Write-Host "[seed] library: $books audiobooks; files still on real library: $leftover (want 0)"
if ("$leftover" -ne '0') { Write-Warning "$leftover AudiobookFiles still reference $RealLibrary" }
Write-Host "[seed] done. Option B (no DataProtection keys: encrypted secrets won't decrypt)."
Write-Host "[seed] launch with:  scripts\run-instance.ps1 -Role $Role"
