# Port to Trio v1.0 — execution plan

Created 2026-09-15. Supersedes the Phase 2 ordering in
`docs/UPSTREAM_SYNC_PLAN.md` (which was written against upstream `dev`, before
v1.0 existed). Background analysis in that doc still applies; this is the
executable version.

**Goal, in the user's words:** update to v1.0 and *use* it, then reimplement the
features we built, on top of it. Modern UI is explicitly dropped — it never
shipped.

---

## 1. The stash (done)

Nothing below can lose work. Before any of it runs:

- **Tag `fork-snapshot-pre-v1.0`** → `fc0af1522`, the fork's pre-port state
  (9 merged features on the v0.8.4 base). Permanent, reachable regardless of
  what happens to `main`.
- **`docs/port/patches/*.patch`** — one self-contained patch per feature,
  extracted as `git diff <merge>^1 <merge>`, i.e. exactly what each PR added to
  `main`. These are the reference material for reimplementation; they are *not*
  meant to be `git apply`-ed onto v1.0 (the files they target have moved or been
  deleted — see §3).

| Patch | Files | Lines |
|---|---|---|
| `01-scheduled-overrides` | 15 | 1173 |
| `01b-scheduled-overrides-BUGFIX` | 21 | 1478 |
| `02-favorite-foods-meal-presets` | 12 | 626 |
| `03-predicted-forecast-tooltip` | 21 | 925 |
| `04-cobiob-chart-future-extension` | 4 | 128 |
| `05-watch-eventual-bg` | 5 | 114 |
| `06-carb-edit-transient-recompute` | 2 | 73 |
| `07-bolus-pills-iob-cob` | 2 | 188 |
| `08-swipe-overrides-temp-targets` | 3 | 212 |
| `09-basal-rate-live-activity-widget` | 11 | 464 |

---

## 2. Branch topology — the thing that stops this recurring

The fork got into a 920-commit hole because `main` was *both* the upstream
mirror and the place custom features live. Those two jobs conflict. Proposal:

| Branch | Role |
|---|---|
| `main` | **Pure upstream mirror.** Reset to `v1.0`, never carries custom code again. The cron's sync step fast-forwards it cleanly, forever, with no conflicts. |
| `trio` | **Long-lived custom branch.** `v1.0` + `fork_ci.yml` + our reimplemented features. This is what gets built and installed. |

At each future upstream release: `main` updates itself via cron; we then merge
`main` into `trio` deliberately, when we choose, with CI and device
verification. One release of drift at a time instead of ten.

**This is what makes "keep the cron on" safe** — the sync step only ever touches
`main`, and `main` will have nothing to conflict with.

Verified: dispatching `build_trio.yml` on a branch that doesn't exist upstream
works fine — the sync step no-ops rather than failing (confirmed empirically by
the `spike/upstream-base` run, `31345446720`, where the step concluded
`success`). So building from `trio` is safe.

### One consequence to decide on

With `SCHEDULED_SYNC` on, the build job's condition includes
`(SCHEDULED_SYNC != 'false' && NEW_COMMITS == 'true')` — so when upstream cuts
v1.1, the cron will sync `main` **and build it to TestFlight**. That build is
*stock Trio*, not your fork.

Not dangerous in itself, but: **if TestFlight auto-update is enabled on the
phone, a stock build can silently replace your custom build on a live AID
system** — you'd lose your features without noticing. Pick one:

- **(a)** Keep cron fully on; turn *off* TestFlight auto-update for Trio on the
  phone and choose builds manually. (Recommended — matches "keep the cron on".)
- **(b)** Keep `SCHEDULED_SYNC` on but set `SCHEDULED_BUILD = false`; a stock
  build still ships when a release lands, so this does *not* fully solve it.
- **(c)** `SCHEDULED_SYNC = false`; sync `main` manually on release. Full
  control, no surprise builds, slightly more manual.

---

## 3. Feature inventory

`fork_ci.yml` must be re-added to `trio` — v1.0's `unit_tests.yml` is still
hard-gated to `github.repository_owner == 'nightscout'` and still only triggers
on `dev`, so it will never run on this fork.

| # | Feature | Disposition |
|---|---|---|
| 1 | Scheduled overrides | **Port the fixed version** — base on `01b` (the `ScheduledOverrideManager` service + tests), not `01`. `01` activates from the view layer; `01b` corrects that and fixes nine QA findings across dosing/remote paths. |
| 2 | Favorite foods / meal presets | Port. Verify first against upstream's `feat/quick-pick-treatments` (#1336) for overlap. |
| 3 | Predicted forecast tooltip | Port, **rebuilt not patched** — `SelectionPopoverView.swift` is deleted in v1.0; target is the new `ChartSelectionRow.swift`, which has no prediction logic of its own. |
| 4 | COB/IOB chart future extension | **DROP.** Upstream shipped it natively (PR #1394) with a cleaner architecture. Do not reintroduce. |
| 5 | Watch eventual BG | Port. Verify first against upstream's watch-forecast PR (#1306). |
| 6 | Carb edit transient recompute | Port. Previously zero collisions — likely the cheapest. |
| 7 | Bolus pills IOB/COB | Port. `TreatmentsStateModel` churned heavily upstream. |
| 8 | Swipe overrides/temp targets | Port. Upstream fixed the shared-delete-confirmation problem differently (#1315, modifier-based); rebuild on their approach, keep our final `TabView` pager. |
| 9 | Basal rate Live Activity widget | Port. Mostly additive on both sides. |
| — | Modern UI / pills+graphs | **DROPPED per user.** Never shipped. `feature/modern-home-layout`, `claude/modern-design-pills-graphs-93qb0r` are abandoned, not ported. |

---

## 4. Task graph

### Layer 0 — Foundation (blocking; human + orchestrator, not subagent work)

| Node | Owner | Deliverable | Verification |
|---|---|---|---|
| `N0.1` Apple Dev Portal: enable Time Sensitive Notifications on the App ID | **human** | Capability enabled | A build gets past the signing step |
| `N0.2` Decide branch topology (§2) and cron option (a/b/c) | **human** | Decision | Stated |
| `N0.3` Reset `main` to `v1.0`; force-push | orchestrator | `main == v1.0` | `git rev-parse main` = `46b559dcd`; tag still resolves |
| `N0.4` Create `trio` from `v1.0`, add `fork_ci.yml` | orchestrator | Branch pushed | Fork CI runs and is green on `trio` |
| `N0.5` Build `trio` → TestFlight; install; **use stock v1.0 for a few days** | **human** | Running v1.0 on device | Pump + CGM + loop working |

`N0.5` is the "update and use" half of the request, and it gates everything
below: no feature work starts until stock v1.0 is known-good on the actual rig.

### Layer 1 — Redundancy triage (parallel, 8 nodes, `suggested_model: sonnet`)

`depends_on: [N0.4]` · `parallel_group: triage` · `domain: research`

One node per feature (1, 2, 3, 5, 6, 7, 8, 9). Each is handed its patch from
`docs/port/patches/` and answers, against the v1.0 tree:

1. Does v1.0 already provide this? (If yes → recommend drop, like #4.)
2. Where does it now belong — exact files/symbols in v1.0, given upstream's
   refactors (oref→Swift, home refactor, alerting rework, DI hygiene).
3. Port strategy: reapply / rebuild / drop, with the specific reasoning.
4. Dosing-adjacent? (flags it for mandatory human review per `CLAUDE.md`)

**Deliverable:** a short written verdict per feature.
**Verification:** verdict cites concrete v1.0 file paths that actually exist,
and explicitly addresses the upstream PR named in §3 where one is listed.

### Layer 2 — Implementation (one node per surviving feature)

`depends_on: [its own Layer 1 node, N0.5]` · `domain: coding` ·
`suggested_model: sonnet` (orchestrator reviews every diff)

Dispatch order — cheapest first, to validate the pipeline before the risky ones:

`6` → `2` → `9` → `5` → `1` → `8` → `7` → `3`

Each node: branch off `trio`, implement against v1.0 APIs, register any new
`.swift` in `project.pbxproj` per the four-section procedure in `CLAUDE.md`,
run SwiftFormat, push.

**Verification, in order — a subagent's "done" is not sufficient:**
1. Orchestrator reviews the actual diff against the node's stated strategy.
2. **Fork CI green** on the feature branch (~20 min; this is the real compile
   and test gate — there is no Swift toolchain in the working environment).
3. Dosing-adjacent nodes (`1`, `7`, and anything Layer 1 flags): **human
   review before merge**, per `CLAUDE.md`.

### Layer 3 — Integration

`depends_on: [all Layer 2]`

Merge each accepted feature into `trio` in dispatch order, Fork CI green after
each. Then one TestFlight build of `trio`, installed and used on the rig.

---

## 5. Honest constraints on executing this

- **No Swift toolchain here.** Linux container, no `swift`/`xcodebuild`.
  Subagents can write code but cannot compile or test it. Every coding node's
  real verification is a GitHub Actions round trip, ~20 min. The graph cannot
  run faster than that gate.
- **Layer 2 is not truly parallel** in practice. Features 1/3/7/8 all touch
  overlapping Home/Adjustments/Treatments territory; running them concurrently
  off the same base creates merge conflicts among *our own* branches. Sequential
  dispatch in the stated order, merging as we go, is correct here.
- **`CLAUDE.md` governs commits.** Edits-only by default; dosing-adjacent code
  gets human verification before it lands.
