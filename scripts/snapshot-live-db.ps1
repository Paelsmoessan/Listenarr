<#
.SYNOPSIS
  WAL-safe snapshot of the LIVE Listenarr DB into _GoldenSnapshot, as the seed source for test instances
  (DEV/VERIFY). Read-only against LIVE (SQLite online-backup API), so the LIVE service can keep running.

.NOTES
  Never raw-copy a live WAL DB (torn image). `.backup` produces a single consistent .db (no -wal/-shm).
#>
[CmdletBinding()]
param(
    [string]$LiveDb = 'C:\ProgramData\Listenarr\bin\config\database\listenarr.db',
    [string]$OutDir = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '_GoldenSnapshot')
)
$ErrorActionPreference = 'Stop'
$sqlite = 'C:\sqlite\sqlite3.exe'
if (-not (Test-Path $sqlite)) { throw "sqlite3 not found at $sqlite" }
if (-not (Test-Path $LiveDb)) { throw "LIVE DB not found at $LiveDb" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$out = Join-Path $OutDir 'listenarr.db'
# clear any prior snapshot (+ stray wal/shm)
Get-ChildItem $OutDir -Filter 'listenarr.db*' -ErrorAction SilentlyContinue | Remove-Item -Force

Write-Host "[snapshot] .backup LIVE -> $out  (WAL-safe; LIVE service can stay running)"
& $sqlite $LiveDb ".backup '$out'"
if ($LASTEXITCODE -ne 0) { throw "sqlite .backup failed (exit $LASTEXITCODE)" }

$sizeMB = [math]::Round((Get-Item $out).Length / 1MB, 1)
$integrity = (& $sqlite $out 'PRAGMA integrity_check;') -join ';'
Write-Host "[snapshot] done: $sizeMB MB, integrity: $integrity"
if ($integrity -notmatch '^ok') { throw "snapshot integrity check FAILED: $integrity" }
Write-Host "[snapshot] golden snapshot ready: $out"
