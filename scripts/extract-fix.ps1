<#
.SYNOPSIS
  Copy ONLY the named fix files from 'canary' onto the current contrib branch.
  Safe replacement for free-hand 'git checkout canary -- ...' (the step fumbled on 2026-07-06).

.DESCRIPTION
  Must run while on a contrib branch (not canary / upstream-canary / main). Checks out the exact
  files from canary, then asserts the staged set equals EXACTLY those files (aborts on anything
  extra), and prints the diff for review. See .claude/plans/fork-contribution-workflow.md.

.EXAMPLE
  ./scripts/extract-fix.ps1 listenarr.infrastructure/Ffmpeg/Metadata/FfprobeMetadataMapper.cs
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Files
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)   # repo root

$branch = (git branch --show-current).Trim()
if ($branch -in @('canary', 'upstream-canary', 'main', 'master', '')) {
  Write-Host "ABORT: on '$branch'. Run this on a CONTRIB branch (make one via new-contrib-branch.ps1)." -ForegroundColor Red
  exit 1
}

# Checkout the exact files from canary (this stages them).
foreach ($f in $Files) {
  git checkout canary -- $f
  if ($LASTEXITCODE -ne 0) { Write-Host "ABORT: could not checkout '$f' from canary." -ForegroundColor Red; exit 1 }
}

# Assert the staged set == exactly the requested files (nothing extra sneaked in).
$want = @($Files  | ForEach-Object { $_ -replace '\\', '/' } | Sort-Object -Unique)
$got  = @(git diff --cached --name-only | ForEach-Object { $_ -replace '\\', '/' } | Sort-Object -Unique)
$extra = @($got | Where-Object { $_ -notin $want })
if ($extra.Count -gt 0) {
  Write-Host "ABORT: unexpected extra files staged - this is NOT the clean set:" -ForegroundColor Red
  $extra | Write-Host
  Write-Host "Undo with: git restore --staged --worktree ." -ForegroundColor Yellow
  exit 1
}

Write-Host "Staged exactly $($got.Count) file(s) from canary:" -ForegroundColor Green
git diff --cached --stat
Write-Host ""
Write-Host "Review -> build/test -> commit -> push -> PR. This branch's base is upstream-canary." -ForegroundColor Cyan
