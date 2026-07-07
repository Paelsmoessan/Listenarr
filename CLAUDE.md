# Listenarr (fork: Paelsmoessan/Listenarr)

Fork of Listenarrs/Listenarr. We run our own build (Windows Service, port 4545) and contribute clean
fixes upstream. This file is fork-only and lives on `canary` (it never leaks into a PR, because contrib
branches are cut clean from `upstream-canary`).

## Fork Contribution Protocol (READ BEFORE ANY BRANCH / PR WORK)

Prevents the 2026-07-06 failure: improvising git across a context reset (cutting branches off the fat
fork, cherry-picking across divergent bases, losing track of "which canary"). Full rationale +
decisions: `.claude/plans/fork-contribution-workflow.md` and `.claude/plans/dm-handoff-fork-contribution-workflow.md`.

### Branch map (never confuse these)
- **`canary`** = OUR fat fork. Windows service, deploy scripts, cover pipeline, big features (TanStack, etc.).
  What we run and deploy. **Author fixes here.**
- **`upstream-canary`** = a local branch that mirrors `upstream/canary` ONLY. The clean contribution base.
  Never receives our work.
- **`fix/*` / `feat/*`** = contrib branches. Always cut from `upstream-canary`, pushed to `origin`, PR'd upstream.

### The flow
1. Author + verify the fix on **`canary`** (full app, real DB).
2. `scripts/new-contrib-branch.ps1 <name>` - refuses a dirty tree, refreshes `upstream-canary` from
   `upstream/canary`, cuts `<name>` from it, asserts the base.
3. `scripts/extract-fix.ps1 <files...>` - copies ONLY those fix files from `canary`; aborts if anything
   extra stages.
4. Build + tests on the contrib branch, then commit, push, `gh pr create --repo Listenarrs/Listenarr --base canary`.

### Hard rules
- **Contrib branches ONLY via `new-contrib-branch.ps1`.** Never hand-cut a branch off `canary`.
- **Move fixes ONLY via `extract-fix.ps1`.** Never free-hand `git checkout canary -- ...` or cherry-pick.
- **Never `git cherry-pick` or `git rebase`** in this repo (cross-base conflicts). Contrib branches are cut
  fresh, not rebased.
- **Only ever touch the fix's explicit files.** Verify `git diff` shows ONLY those before committing.

### Enforcement (survives /clear)
- **Hook:** `.claude/settings.json` PreToolUse guard (`scripts/git-guard.sh`) hard-DENIES raw
  `cherry-pick` / `rebase` and cutting a branch off `canary`, pointing back at the scripts. It fires
  regardless of what the model remembers.
- **Portability:** `.claude/settings.json` is gitignored (local-only), so on another machine the guard
  SCRIPT arrives via the fork but the hook must be re-wired there (drop in the same `.claude/settings.json`,
  adjusting the absolute path). `jq` is NOT installed on these machines; the guard is deliberately jq-free.
