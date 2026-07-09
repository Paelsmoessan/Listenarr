# Listenarr Fork — TODO

## Known Bugs

- **EF migration drift in our fork's DB (surfaced by upstream PR #727).** Upstream found two migrations were
  never discovered by EF, so real installs (ours included) are missing `MoveJobs.SourcePath` and the entire
  `ProcessExecutionLogs` table. Symptom if it bites: `SQLite Error: no such column: m.SourcePath` or
  `no such table: ProcessExecutionLogs`. Fix path = adopt upstream #727 (restores the Designer + adds the
  `AddProcessExecutionLogs` migration; heals on next startup) or its approach. NOT yet verified on our DB, not
  pulled. Decision 2026-07-07: "we do us, they do them" — parked; pull if/when it actually bites. Quick check:
  `'/c/sqlite/sqlite3.exe' <db> "SELECT name FROM sqlite_master WHERE name='ProcessExecutionLogs';"` (empty = drifted).

## Dev Tooling
- **Split the deploy script into frontend-only / backend-only / both.** `scripts/update-from-upstream.ps1`
  currently rebuilds and swaps FE+BE every time, which is slow for incremental changes. Separate targets
  (deploy FE only via `npm run build` + robocopy `fe/dist` -> `wwwroot`, no restart; deploy BE only =
  `dotnet build` + swap bin + restart; and "both") would speed up the test loop a lot.
- **Adapt the contribution scripts to the worktree restructure (2026-07-08).** Repo is now
  container + `_DevFork` (canary) + `_Upstream` (upstream-canary). Two breakages to fix in
  `new-contrib-branch.ps1`: (1) `git branch -f upstream-canary upstream/canary` now FAILS because
  `upstream-canary` is permanently checked out in `_Upstream` — refresh via the worktree instead
  (`git -C _Upstream fetch upstream; git -C _Upstream reset --hard upstream/canary`). (2) Contrib branches
  should be cut/checked-out in the `_Upstream` worktree (so VERIFY can run them), not in the `_DevFork`
  (canary) tree. See `.claude/plans/test-instances-harness.md` + `project_repo_worktree_layout` memory.
- **Decide push handling for the worktree layout (DISCUSS, 2026-07-08).** Now that `_DevFork` (canary) and
  `_Upstream` (contrib branches) are separate worktrees of one repo, settle: cadence for pushing `_DevFork`
  canary -> `origin/canary` (fork backup) vs keeping it local; how contrib branches push from `_Upstream` ->
  `origin` for PRs; and whether/what fork-only tooling commits (e.g. run-instance.ps1 `727620dc`) get pushed.
  Not decided yet - flagged to discuss before the next push.
- **Update Node.js (env, 2026-07-08).** Installed Node is `v20.18.1` (single install, `C:\Program Files\nodejs`).
  The fe toolchain wants newer: Vite 8 requires `>=20.19 / 22.12` (prints an upgrade warning on every build),
  and `fe` engines want `^24.15.0`. The FE still builds today (warning only), but it is a latent hard-fail risk
  as deps bump their floor. Update to Node 22 LTS (or 24). Confirmed via the run-instance.ps1 FE build
  2026-07-08 (see reason-notes "run-instance.ps1 FE build" chapter).
- **Test-instance shutdown control (2026-07-08).** While testing via the browser there's no obvious way to
  stop the running exe. Today: Ctrl+C in the launching console (run-instance.ps1's finally stops the app) or
  close that console. Wanted, two options: (a) a `stop-instance.ps1 -Role Dev|Verify` helper that kills the
  instance by port / content-root (pure tooling, zero product code) - the quick win; (b) Chris's idea: an
  in-app Shutdown button in the UI, gated to TEST instances ONLY (e.g. a LISTENARR_TEST_MODE flag / non-4545
  port), never on LIVE - nicer UX but it's fork product code + must be hard-gated so it can never appear on
  the live 4545 service.

## Fork Maintenance — SOLVED 2026-07-07 (guarded branch workflow)
- Built the guarded single-fork branch model that fixes the #731 base-divergence pain: `upstream-canary`
  local mirror = clean base; author/verify on `canary`, then `scripts/extract-fix.ps1 <files>` copies only
  the fix files onto a branch cut via `scripts/new-contrib-branch.ps1` (off `upstream-canary`, never fat
  canary). A PreToolUse hook (`scripts/git-guard.sh`) hard-blocks raw cherry-pick/rebase/wrong-base cuts so
  it survives `/clear`. Full protocol in `CLAUDE.md`; rationale in
  `.claude/plans/fork-contribution-workflow.md`. Committed c0390c6f + 37453ccb, pushed.
- Open follow-ups: re-wire the hook on dev2 (`.claude/settings.json` is gitignored/local; the guard script
  travels via the fork); real-world shakedown on the next actual upstream fix; cadence for pulling wanted
  upstream changes back into `canary` (merge, not rebase) still to define.

## Fixed

### Sidebar nav: sub-branch items don't react until the parent top node is hovered
- **Fixed 2026-07-04** (canary `c9245e6b`, upstream PR #734). Two causes in `fe/src/App.vue`:
  `.nav-subitem` had no `:hover` / `:focus-visible` style at all (only default + `.active`), and
  `.nav-sub` was collapsed with `pointer-events: none` until opened by a parent hover. Added the hover
  highlight and made the sub-navs stay expanded so children are always interactive.

## Enhancements
- **Semi-static cover/author image cache** (Part 4 of `.claude/plans/books-page-freeze-fix.md`):
  pre-warm all grid thumbnails, durable "no-cover" marker, serve thumbs via static-file middleware.
  Makes cover browsing fast on first paint. Builds on the shipped CoverThumbnailService.
- **Oversized-thumbnail byte guard** (nice-to-have, 2026-07-05). `CoverThumbnailService` resizes to
  400px and encodes at `JpegQuality = 80`, which is fine for 99.8% of covers (avg 34KB). But 2 of
  1076 thumbs are pathological (B001JP7WJC = 731KB at 300x400, B002M4H17M = 617KB at 267x400): the
  source art won't compress at Q80. Add a post-encode guard: if the output exceeds a cap (say 150KB),
  re-encode at a lower quality (or smaller max edge) so no "thumbnail" is near original size. 0.2% of
  the library, purely cosmetic. Verified 2026-07-05 that the grid otherwise serves thumbs correctly
  (e.g. 1570KB original to 65KB via ?size=grid).

## Design (larger, separate from PR #733)
- **Canonical cover identity** (follow-up from PR #733 review, 2026-07-05). The image cache today
  names files by a *sanitized identifier* (`ImageCachePathResolver.SanitizeFileName`), and the
  frontend addresses the same cover under different strings depending on the view: authors by ASIN
  (`/images/{authorAsin}`) vs by name (`ensureAuthorCover`), books by stored `imageUrl` stem vs
  `book.asin` fallback, plus case sensitivity. Result: the same cover is cached under multiple keys.
  ASIN is also not future-proof (authors lack it; non-Audible providers like Phonotheca have none).
  Hashing filenames does NOT fix this on its own (hash of a different input = a different file).
  Real fix = pick ONE canonical key per entity and address every cover by it. Two candidate shapes:
  (A) MediaCover-style internal DB entity id (`images/authors/{authorId}.jpg`), provider-agnostic,
  no hash needed, but does not cover pre-library search-result thumbnails (no entity id yet);
  (B) hash of a canonical provider key (normalized ASIN, else ISBN, else source URL), covers search
  results too. Touches frontend URL builders + backend resolution, so write a plan first. See
  `.claude/reason-notes.md` for the full data-flow trace.

## Library Matching / Metadata Mapping
- **Reclaim the ~1000 unmatched audiobooks.** Real books that Listenarr could not scrape/match, parked in
  M:\ root folders (`_audiobook_cleanup`, `_ToBeDeleted`, `Uploaded` — leftovers from failed readarr /
  lazylibrarian imports). Chris keeps them deliberately (they are library we do not otherwise have); the fix
  is BETTER MATCHING, not deletion. This is the concrete motivation for improving the matcher.
- Approaches (from vetted research + prior decisions):
  - Matching robustness: bracket-stripping before title compare, single language-filter polarity,
    duration-weighted match scoring (ABS-style 0.7 duration / 0.2 title / 0.1 author). Source:
    `D:\_Development\Phonotheca\.claude\research\audible-matching-pitfalls\report.md`.
  - Phonotheca provider for Listenarr: typo tolerance + relevance ranking that the current exact-spelling
    search lacks (memory `project_phonotheca_metadata_provider`, `project_audiobook_metadata_server`).
- Deliberately NOT starting yet; captured so it is not lost as the reason those chaotic folders stay.
