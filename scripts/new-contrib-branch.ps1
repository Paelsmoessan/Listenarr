<#
.SYNOPSIS
  Start a clean, upstream-based contribution branch. The ONLY sanctioned way to cut a contrib branch.

.DESCRIPTION
  Refuses a dirty tree, refreshes the 'upstream-canary' mirror from upstream/canary, cuts the new
  branch from that mirror, then prints and asserts state. NEVER cuts from our fat 'canary'.
  See .claude/plans/fork-contribution-workflow.md.

.EXAMPLE
  ./scripts/new-contrib-branch.ps1 fix/1234-widget
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$BranchName
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)   # repo root

# 1. Working tree must be clean.
$dirty = git status --porcelain
if ($dirty) {
  Write-Host "ABORT: working tree is not clean. Commit or stash first:" -ForegroundColor Red
  $dirty | Write-Host
  exit 1
}

# 2. Fetch upstream's canary.
Write-Host "Fetching upstream/canary..." -ForegroundColor Cyan
git fetch upstream canary
if ($LASTEXITCODE -ne 0) { Write-Host "ABORT: 'git fetch upstream' failed." -ForegroundColor Red; exit 1 }

# 3. Refresh the mirror so it exactly equals upstream/canary.
git branch -f upstream-canary upstream/canary
if ($LASTEXITCODE -ne 0) { Write-Host "ABORT: could not refresh 'upstream-canary'." -ForegroundColor Red; exit 1 }

# 4. Cut the contrib branch from the mirror (never from our fat canary).
git switch -c $BranchName upstream-canary
if ($LASTEXITCODE -ne 0) { Write-Host "ABORT: could not create '$BranchName' (already exists?)." -ForegroundColor Red; exit 1 }

# 5. Assert the base and print state.
$base = (git rev-parse upstream/canary).Trim()
$here = (git rev-parse HEAD).Trim()
Write-Host ""
Write-Host "On branch: $(git branch --show-current)" -ForegroundColor Green
if ($here -eq $base) {
  Write-Host "Base: upstream/canary ($($base.Substring(0,9))) - clean base confirmed." -ForegroundColor Green
} else {
  Write-Host "WARNING: HEAD ($here) != upstream/canary ($base). Investigate before continuing." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Next: author/verify the fix on 'canary', then run" -ForegroundColor Cyan
Write-Host "      scripts/extract-fix.ps1 <files...>   to copy only the fix files onto this branch." -ForegroundColor Cyan
