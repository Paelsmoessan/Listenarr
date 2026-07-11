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
- **FIX deploy.ps1 health check - it throws on 4xx and cost ~3hrs on 2026-07-11 (HIGH PRIORITY).** Root cause of
  the entire "BE won't run as a service" saga: `Start-And-Verify` does `Invoke-WebRequest $HealthUrl` where
  `$HealthUrl` = `http://localhost:4545` (ROOT). PowerShell's `Invoke-WebRequest` THROWS on any 4xx, so when `/`
  returned 404 (because wwwroot was missing index.html) the health check caught it and reported "not responding"
  -> auto-rollback every time, even though the app was serving fine (401 on /api, 200 on /favicon.ico). FIX:
  (a) catch the WebException and treat ANY HTTP status < 500 as healthy (a 404 means the server IS up), OR probe
  a guaranteed-2xx path like `/favicon.ico` instead of `/`. (b) ALSO: a BE/Both deploy should verify wwwroot has
  `index.html` after swapping (BE publishes with SkipFrontendBuild + BE swap preserves wwwroot via /XD, so a
  broken wwwroot stays broken silently). Full post-mortem: reason-notes "RESOLVED" banner 2026-07-11.
- **Native Windows Service WRAPPER - WANTED as the RESILIENCE BRIDGE (Chris, 2026-07-11 night: "it needs to be
  the bridge that cancels out sheit like this").** Not just crash-restart - it should be the layer that makes
  tonight's class of failure IMPOSSIBLE: (1) own a CORRECT health check (probe a real endpoint / treat 4xx as
  "up" / confirm Kestrel is listening on 4545) so a working app is NEVER misread as dead; (2) restart the child
  app on a genuine crash (already built - launch/monitor/backoff); (3) optionally validate a deploy is sane
  (e.g. wwwroot has index.html, exe present) and report TRUE health to the SCM, so a bad deploy surfaces loudly
  instead of silently rolling back a healthy app. Also sidesteps the real `WindowsServiceLifetime` #72590 bug.
  (4) **VERBOSE LOGGING = TOP PRIORITY (Chris, 2026-07-11 night).** The wrapper must log LOUDLY and in detail:
  child process launch (PID, exe path, args), each health-probe attempt + its result (which endpoint, status
  code, latency - so "401 = up" is obvious), every restart with the reason, exit codes, and how long the child
  took to become healthy. This is the OBSERVABILITY LAYER that would have turned tonight's silent 3-hour ghost
  hunt into a 2-minute log read. **Rationale (Chris):** it's the early-warning system for **incorporating
  upstream fixes** - when we adopt/"cherry-pick" landed upstream changes into the fork, a verbose wrapper catches
  a silent regression (like tonight's) immediately at deploy time instead of costing hours. Prioritize this over
  the fancy resilience features.
  STATUS: BUILT + proven in isolation (`listenarr.servicehost/`: Program.cs + ProcessSupervisorService.cs,
  generic host, launch/monitor/auto-restart verified via a real separate test service). Committed `3f63f152`.
  Remaining work: (a) add VERBOSE health/lifecycle LOGGING (priority, see #4), (b) add the correct health-probe
  logic (probe a real endpoint / treat 4xx as up - NOT `/`), (c) fix the deploy COPY so the wrapper's FULL
  self-contained publish output ships (not a hand-picked file list - that took LIVE down once tonight),
  (d) carefully repoint the real service at the wrapper. Do with a fresh head; Chris owns deploys.
- **Native Windows Service WRAPPER in the fork - DECIDED 2026-07-11 (Chris, firm: "we need to build a service
  wrapper, I am not doing this again").** Today the app registers itself with the SCM in-process via
  `builder.Host.UseWindowsService()` (`Program.cs:31` + the `Microsoft.Extensions.Hosting.WindowsServices`
  package, from commit `2c1e2bb5` 2026-06-18). That in-process integration is the fragile part. Build a
  **dedicated native Windows service (a separate small process) that launches + monitors the API exe and owns
  health/lifecycle** (start/stop/recovery), decoupled from the app itself. Fork-only. Plan:
  `.claude/plans/windows-service-support.md`.
  - **WHY (evidence 2026-07-11):** a fresh BE deploy would NOT stick. The new self-contained single-file exe,
    run as the in-process Windows service, reaches SCM Running, applies EF migrations (log 19:22:44) and starts
    its hosted services, BUT **never answers HTTP on 4545 even given 240s** (deploy.ps1 auto-rolled-back at 60s;
    a manual swap with a 240s window ALSO failed -> restored old bin). The old July-6 build serves fine, so the
    serve-as-service path regressed. Grid (FE) IS live; only the BE couldn't be redeployed.
  - **Leads for the wrapper / root-cause (not chased further tonight):** (a) the 4545 URL binding is CONDITIONAL
    in `ListenarrBuilderFactory.cs:213-219` (`builder.WebHost.UseUrls("http://*:4545")` gated by a condition) -
    if it doesn't fire under the service context, the app binds the default port, not 4545, and the 4545 health
    probe fails. (b) OR `app.RunListenarrStartupTasksAsync()` (awaited BEFORE `app.Run()` in Program.cs) blocks
    the app from ever listening. A wrapper that owns health independent of the app's cold-start sidesteps both and
    makes deploys reliable.
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
- **Update Node.js — DONE 2026-07-11.** Was `v20.18.1` (below Vite 8's `>=20.19/22.12` and `fe` engines
  `^24.15.0`). Replaced with **nvm-windows 1.2.2** + **Node 24.18.0** (npm 11.16.0); `20.18.1` kept installed as
  an instant rollback (`nvm use 20.18.1`). nvm symlink lives at `C:\nvm4w\nodejs` (on machine PATH). FE build
  verified exit 0 on 24, Vite warning gone. Gotcha: a long-lived shell opened before the swap carries a stale
  PATH (old `C:\Program Files\nodejs`, now gone) - refresh PATH or open a fresh shell so `node`/`npm` resolve.
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
- **Clamp the center row across the info-details toggle** (Chris, 2026-07-11). Toggling info on/off changes
  row height, so the grid jumps away from where you were browsing. Anchor the center-visible row across the
  toggle: capture that row's item key just before the height change, then `scrollToIndex(thatRow, align:'center')`
  after. Reuses the VirtualGrid index-restore mechanism (same as back-nav restore), applied to the toggle so
  you land in the ballpark of your current position instead of jumping.
- **Authors/Series grouped view: slow cover loading + not virtualized** (Chris, 2026-07-11). The grouped
  authors/series view (`groupBy !== 'books'`) is NOT wrapped in VirtualGrid, it renders ALL collections at
  once, so every cover loads/decodes up front = slow on large libraries (Chris: covers load slow on Series).
  Two threads: (1) extend the VirtualGrid slot pattern to the grouped authors + series grids (was in the
  original TanStack migration scope, never done) so only a screenful renders; (2) investigate **author cover
  photo** perf/resolution specifically (author covers resolve via ASIN/name `ensureAuthorCover`, may be a
  separate slow path from book covers). Books grid already gets the cache/overscan/lazy wins; grouped views do
  not yet.
  **Confirmed still too slow on Series 2026-07-11** (after the cache/lazy/overscan/page-fade pass, which only
  touched the books path). Primary fix = the window-scroll virtualization redesign applied to ALL modes
  (books + authors + series) so the grouped views render only a screenful. Track under that redesign.

## Feature: list view for Authors and Series
- **Only Books have a grid/list toggle** (Chris, 2026-07-11). Authors + Series are grouped-grid only. Extend the
  list view (the `.audiobook-list-item` row pattern + `.list-header`) to the grouped modes so authors/series can
  also be listed, not just gridded. Would ride the same VirtualGrid list mode (fixedColumns=1 + fixedRowHeight)
  the books list migration would use. (Books list itself: works today on the old scroller, no longer flashes
  after the viewMode-restore-in-setup fix; migrating it to the VG is optional cleanup, not urgent.)

## Perf principle: remove anything that adds perceptible latency
- **Guiding rule (Chris, 2026-07-11): everything that slows things down is unwanted in the long run.** This is
  a management tool - instant + reliable beats cosmetic polish. Already applied: removed the page-fade route
  transition (big win), thumbnailed all covers, virtualized all modes.
- **Remove the cover-image fade-in** (all modes). The `.cover-loading-image` / `.loaded` classes fade each cover
  `opacity 0 -> 1` over ~0.2s as it loads, so covers dribble in instead of snapping. Books + series use
  `cover-loading-image`; authors use the `audiobook-poster.author-cover` / `.loaded` fade + `author-placeholder`.
  Kill the opacity transition (+ the `.loaded` gating / any `img.style.opacity='0'`) so covers appear
  immediately. Shared-class CSS change across all modes. Verify no flash of broken-alt.

## Perf: pre-warm author cover photos (first-run Authors lag)
- **Authors lags on first run; Series + Books don't** (Chris, 2026-07-11, confirmed after the redesign). Root:
  book + series covers are pre-generated by `CoverThumbnailWarmupService` (series covers ARE book covers), so
  they're on disk before you browse. AUTHOR photos are resolved on-demand (`ensureAuthorCover` fetch + thumb)
  the first time you open Authors = the lag; cached fast after. Fix: extend the warmup service (or add a sibling)
  to pre-warm author covers too (iterate authors, ensureAuthorCover + thumbnail), so Authors is instant like the
  others. Separate from the grid; ties to the "everything slow is unwanted" principle above.
  **Confirmed it's a REWIRE, not a refactor (2026-07-11):** author-photo resolution already lives in reusable
  workflow services - `MetadataAuthorLookupWorkflow` (the `/metadata` author-lookup the FE `getAuthorLookup` hits)
  + `ImageCandidateLookupWorkflow.Authors` (TryResolveAuthorFallbackAsync -> AudibleService.LookupAuthorAsync) -
  and `CoverThumbnailService` makes the thumb. So: add an AUTHOR pass to CoverThumbnailWarmupProcessor (iterate
  distinct authors -> call the existing author-lookup workflow to resolve+cache the photo -> thumbnail it), same
  shape as the book pass. Only impl detail = DI the workflow into the warmup like it already scopes
  IAudiobookRepository. No new resolution code.

## Bug: author photo / name mismatch (co-authors) — CHECK BACKEND
- **An author card shows the WRONG person's photo** (Chris, 2026-07-11, screenshot): card labelled "Jerry
  Pournelle" (1 book) displays a photo of **Larry Niven**. Name and photo are different people. Niven & Pournelle
  are frequent co-authors, so this is almost certainly the co-author path: the group NAME comes from
  `book.authors?.[0]` while the author COVER is resolved from a different source (authorAsins[0] via
  groupedCollections, and/or `ensureAuthorCover(name)` -> backend author-image lookup). If authors[] and
  authorAsins[] are misaligned, or the backend name lookup returns the wrong co-author, name and photo diverge.
- PRE-EXISTING (not caused by the authors-VirtualGrid change; groupedCollections + cover resolution untouched;
  would show the same in the old view). Chris: **check the BACKEND** author-image resolution + the
  authors/authorAsins alignment. FE entry points to trace: groupedCollections author-cover pick (~1544-1563),
  ensureAuthorCover (1591), getAuthorImageUrl.

## Bug: cover full-size loads
- **FIXED 2026-07-11 (b366e89f):** direct `/config/cache/images/**` file URLs bypassed `?size=grid`
  thumbnailing (served full-size 100-264KB). Consolidated getImageUrl's two duped library/authors rewrites
  into one general cache-path rule that routes any cache path through `/api/images/{id}?size=grid`. Verified:
  author covers now ~9-41KB thumbnails.
- **Remaining minor outlier:** one cover was seen loading full-size (204KB) via `/api/images/B01CO38PWA` with
  NO `?size=grid` param at all (different from the cache-path bug, a call site not passing the size option).
  Low priority; find the call site that omits `{ size: 'grid' }` and pass it. (Also the pre-existing
  oversized-thumbnail guard idea below for covers that don't compress under q80.)
- **User-selectable overlay/caption fields, arr-style** (Chris, 2026-07-11). In Radarr/Sonarr you pick which
  metadata fields the poster shows; each selected field adds ONE uniform line to EVERY card (shown or blank).
  This is both a feature (user controls density) AND a geometry win: row height = number of selected fields =
  deterministic by construction, NO whole-library maxDetailLines scan, NO conditional per-card lines. Replaces
  today's "narrator/series line only if present" (which varies per card and needs the scan). Staying true to the
  *arr design (Chris's constraint) = adopt this model. Pieces: (1) render the details block from a FIELD LIST
  (not hardcoded conditionals) so N fields = N lines; (2) a small Poster-Options UI to toggle fields; (3)
  persist the selection (localStorage or ApplicationSettings). Build the grid-redesign details block field-list-
  driven now (default = today's fields) so adding the UI later is small. See
  .claude/plans/grid-redesign-unified-virtualizer.md.
- **Review the AUTHORS info-on details block** (Chris, 2026-07-11). After virtualizing authors, the info-on
  details are currently just name + count (fixed 2-line reserve, authorsExtraHeight=42px). Needs a proper look:
  what fields authors should show, layout/spacing vs the book cards, and fold it into the field-list-driven /
  configurable-fields model above rather than the ad-hoc 2-line block. Same review likely applies to series
  details when that mode is virtualized (step 2).

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
