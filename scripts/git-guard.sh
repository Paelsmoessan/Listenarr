#!/usr/bin/env bash
# PreToolUse guard (matcher: Bash, gated with if:"Bash(git *)").
# Blocks the exact git operations that caused the 2026-07-06 fork-branch mess, and points at the
# safe scripts instead.
#
# DEPENDENCY-FREE by design: jq is NOT installed on this machine, so we do NOT parse the JSON.
# We grep the raw hook payload (stdin) for the dangerous forms and hand-build the deny JSON.
# Biased to block: a rare false-positive deny is safe; a false-negative allow is the thing we can't have.
# Anything not matched => exit 0 with no output => normal permission flow (allowed).

input=$(cat)

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# NOTE: patterns match the git SUBCOMMAND (right after 'git' + optional global flags), NOT the word
# anywhere in the line — so 'git commit -m "...cherry-pick..."' is NOT blocked, only 'git cherry-pick'.

# 1. raw cherry-pick — caused cross-base conflicts. Force the extract-fix path.
if printf '%s' "$input" | grep -qiE '\bgit[[:space:]]+((-[cC][[:space:]]+[^[:space:]]+|-[^[:space:]]+)[[:space:]]+)*cherry-pick\b'; then
  deny "Blocked: raw git cherry-pick in this repo (it caused cross-base conflicts on 2026-07-06). To move a fix onto a contrib branch use scripts/extract-fix.ps1 <files...> which copies ONLY the named files."
fi

# 2. raw rebase — no rebasing across divergent bases.
if printf '%s' "$input" | grep -qiE '\bgit[[:space:]]+((-[cC][[:space:]]+[^[:space:]]+|-[^[:space:]]+)[[:space:]]+)*rebase\b'; then
  deny "Blocked: raw git rebase in this repo. Contrib branches are cut fresh from upstream-canary via scripts/new-contrib-branch.ps1 - no rebasing across divergent bases."
fi

# 3. cutting a NEW branch off canary / origin/canary — wrong base; bloats upstream PRs.
#    (Plain 'git switch canary' / 'git checkout canary' do NOT match — only -c/-b with canary as base.)
if printf '%s' "$input" | grep -qiE '\bgit[[:space:]]+(switch[[:space:]]+-c|checkout[[:space:]]+-b)[[:space:]]+[^[:space:]]+[[:space:]]+(origin/)?canary\b'; then
  deny "Blocked: cutting a contrib branch off canary bloats upstream PRs (the 24-file mess). Use scripts/new-contrib-branch.ps1 <name> which cuts from upstream-canary."
fi

exit 0
