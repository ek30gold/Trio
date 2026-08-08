# Upstream Sync Plan — ek30gold/Trio → nightscout/Trio

Status: **Phase 1 in progress**
Last updated: 2026-08-08

---

## 1. Where we actually are

The fork branched from the **v0.8.4 stable release** of `nightscout/Trio`
(commit `29350e31`), *not* from the `dev` branch.

| | `APP_VERSION` | `APP_DEV_VERSION` |
|---|---|---|
| `ek30gold/Trio` (this fork) | 0.8.4 | 0.8.4 |
| `nightscout/Trio` @ v0.8.4 release | 0.8.4 | 0.8.4 |
| `nightscout/Trio` @ `dev` HEAD | 0.8.4 | 0.8.4.47 |

The `(40)` build number shown in TestFlight is this fork's own CI counter. It is
**not** upstream dev build 40. The in-app version checker line
"Latest dev: 0.8.4.47 ↑" is comparing against a *different release track*.

**Real gap: ~920 commits, 440 files changed upstream.**
This fork carries 11 merge commits (8 shipped features) touching 51 files, of
which **28 collide** with files upstream also changed.

### Reference commits

| Ref | Commit | Meaning |
|---|---|---|
| Fork base | `29350e31` | upstream v0.8.4 release — the merge-base |
| Fork `main` | `c68f659` | after PR #8 |
| Upstream `dev` | `469562376` | `0.8.4.47` at time of writing |

---

## 2. What upstream changed

Five changes are structural, not incremental.

**1. oref: JavaScript → native Swift.** PRs #1141, #1273, #1317, #1316 ported the
OpenAPS algorithm to Swift and then *deleted* the JS engine. New
`Trio/Sources/APS/OpenAPSSwift/` tree: `DosingEngine.swift` (917 lines),
`DetermineBasalGenerator.swift` (737), `IobHistory.swift` (485),
`ForecastGenerator.swift` (433), `AutosensGenerator.swift` (433), `MealCob.swift`,
`ProfileGenerator.swift`. `OpenAPS.swift` went 1010 → 808 lines with a changed
function surface.

**2. Home screen refactor** (#1373, plus #1326–#1332). `HomeRootView.swift` gutted
and split into `+BottomControls` (758 lines), `+Header`, `+MealPanel`, `+Refresh`;
new `GlassChrome.swift` (liquid glass), `HomeLayout.swift`,
`MultiUsePanelState.swift`, `HomeStatsPanelFace.swift`, sensor-lifecycle arc.
`MainChartView.swift`: 1040 lines churned.

**3. Alerting / notifications rework** (#1203, #1269, #1307). New
`Services/Alerts/`: `TrioAlertManager` (579), `GlucoseAlertCoordinator` (484),
`TrioModalAlertScheduler` (449), `AlertCatalogRegistry` (259).
`UserNotificationsManager.swift` churned 598 lines. `MainStateModel.swift` −307.

**4. APSManager refactor** parts 1–3 (#1225–#1227), 631 lines churned, plus Core
Data fixes (#1107).

**5. New device support.** AccuChekKit and EversenseKit added as **new git
submodules**; Medtrum / OmnipodKit / G7SensorKit bumped; Omnipod BLE heartbeat
wired to the CGM read schedule; Garmin complication; watch forecast; quick bolus;
Live Activity prediction.

---

## 3. Collision analysis

### 🔴 Structural — the code we patched no longer exists

| File | Upstream churn | Ours | Why it's hard |
|---|---|---|---|
| `APS/OpenAPS/OpenAPS.swift` | 714 | 69 | Our `fetchAndProcessCarbs() -> (String, Date?)` change targets a function **upstream deleted**. Carbs now come from `carbsStorage.getCarbsForAlgorithm(...)` returning typed `[CarbsEntry]` / `ComputedCarbs`, not RawJSON. `processDetermination` now takes an explicit `context:` param. |
| `Home/View/Chart/MainChartView.swift` | 1040 | 47 | Rewritten around the new home layout. |
| `Treatments/TreatmentsStateModel.swift` | 439 | 85 | Heavy churn under our bolus-pill IOB/COB work. |
| `Services/UserNotifications/UserNotificationsManager.swift` | 598 | 28 | Superseded by the new `Services/Alerts/` stack. |
| `Home/HomeStateModel.swift` | 706 | 3 | Our 3 lines are trivial to re-add; the file around them is unrecognizable. |

### 🟡 Semantic — merges cleanly but may be *wrong*

Git will not flag these. Each needs eyes on the merged result, not just a
conflict-free status.

- `HomeStateModel+Setup/ForecastSetup.swift` — ours +88, upstream 21. Forecast
  generation moved into `OpenAPSSwift/Forecasts/`.
- `Home/View/Chart/ChartElements/SelectionPopoverView.swift` — 73 up / 105 ours.
- `APS/Storage/DeterminationStorage.swift` — 59 up / 60 ours.
- `APS/Storage/OverrideStorage.swift` — 47 up / 49 ours.
- `Home/View/Chart/ChartElements/CobIobChart.swift` — 109 up / 59 ours.

### 🟢 Mechanical

`Screen.swift`, `WatchMessageKeys.swift`, `Determination.swift`, both
`WatchState.swift`, `FeatureSettingsView.swift`, `SettingItems.swift`,
`TempTargetsStorage.swift`.

**CoreData model:** upstream changed *only* the `lastSavedToolsVersion` attribute
on the root `<model>` element. Our four new projection entities
(`IOBProjection`, `IOBProjectionValue`, `COBProjection`, `COBProjectionValue`)
plus the `MealPresetStored.note` / `.orderPosition` attributes drop in clean.

**`Trio.xcodeproj/project.pbxproj`** (1334 up / 36 ours): mechanical. Resolve by
taking upstream wholesale, then re-registering our files per the four-section
procedure in `CLAUDE.md`.

### Two findings that change plans

**PR #8 (swipe on Adjustments) partly duplicates upstream #1315.** Upstream
independently fixed the shared delete-confirmation state — but via a
`confirmationDialog` **view modifier**, not our split into
`isConfirmOverrideDeletePresented` / `isConfirmTempTargetDeletePresented`.
Upstream also kept `.tag(index)` where we moved to `.tag(item)`, and still uses
`switch state.selectedTab` with one subtree live. Our "both tabs render
simultaneously" transformations (`defaultText` / `currentActiveAdjustment` as
functions taking an explicit tab) must be redone against their code.

**`feature/modern-home-layout` — the hook point survives, but reconsider the
feature.** `mainViewElements(_ geo: GeometryProxy) -> some View` still exists
upstream with an identical signature. Upstream turned it into a chrome wrapper
(ScrollView + pull-to-force-loop + `bottomControls()`) and moved the layout into a
new `dashboardContent(_ geo:)`, whose body is nearly line-for-line our
`classicViewElements`. **So our switch moves down one level, into
`dashboardContent`.** No symbol collisions (`ModernCard` / `ModernChip` /
`HomeLayoutStyle` vs upstream `HomeLayout` / `GlassChrome` / `HomeStatsPanelFace`).

Caveats: upstream is already doing its own home modernization (liquid glass,
sensor arc, multi-use panel, stats faces, `modernTabBar()`) — evaluate whether
ours is still worth 850 lines. And `DummyCharts.swift`, which our branch modifies,
**was deleted upstream** → delete/modify conflict.

**`claude/trio-basal-rate-widget-2ikgez` has 8 collisions, not 1** (upstream's
Live Activity prediction PR #1194 touched the same stack). Upstream's LiveActivity
churn is only +225/−24 and mostly additive, so this stays tractable.

---

## 4. Phase 0 — Decide the base (blocking)

Upstream has **no v0.8.5 release yet**; `main` is still v0.8.4.

- **Option A — port onto `dev` now.** Gets oref-swift, home refactor, new drivers.
  Cost: running *pre-release closed-loop dosing code*. The oref JS→Swift port is a
  from-scratch reimplementation of the dosing algorithm.
- **Option B — wait for v0.8.5, port onto the release tag.** Same work, done once,
  against code that passed upstream release testing. **Recommended.**
- **Option C — stay on v0.8.4.** Cheapest now, worst later.

Recommendation: **B**, but run the Phase 1 spike now — it is throwaway-cheap and
informative — and use the waiting time to judge whether upstream's home refactor
makes our Modern layout redundant.

---

## 5. Phase 1 — Baseline spike (throwaway, ~half a day)

Do **not** merge anything. Establish ground truth.

1. Add `upstream` remote. *(done — see §8)*
2. Branch `spike/upstream-base` from `upstream/dev`; `git submodule update --init
   --recursive` (picks up AccuChekKit + EversenseKit).
3. **Build and run it clean, with none of our features.** Confirm upstream `dev`
   works on the actual phone + pump + CGM.
4. Run the test suite for a green baseline.
5. Live with the stock home refactor for a few days.

**Gate:** if upstream `dev` does not build and run clean, stop. Nothing
downstream matters until it does.

---

## 6. Phase 2 — Re-port, feature by feature

**Do not `git merge upstream/dev` into `main`.** With 920 commits, 28 collisions,
and dosing-adjacent semantic conflicts that merge *silently*, a big-bang merge is
the wrong tool for safety-critical code. Branch each feature fresh off the new
base and re-apply it as a fresh implementation *informed by* the old diff.

Order puts cheap wins first to validate the process before the hard ones.

| # | Feature (orig PR) | Risk | Notes |
|---|---|---|---|
| 1 | Carb edit transient recompute (#6) | 🟢 | `HistoryStateModel+CarbEditing/+Carbs` — **zero collisions**. Pure re-apply. |
| 2 | Favorite foods / meal presets (#2) | 🟢 | Mostly new files + 2 CoreData attributes. Only `Screen.swift` collides (21/3). |
| 3 | Watch eventual BG (#5) | 🟡 | `AppleWatchManager` churned 125; check for duplication against upstream's watch-forecast PR #1306. |
| 4 | Scheduled overrides (#1) | 🟡 | `OverrideStorage` 47/49, `OverrideSetup` 85/27. |
| 5 | Swipe on Adjustments (#8) | 🟡 | Rebuild on upstream's modifier-based confirmation dialog. Keep the final `TabView` approach — do not re-derive the three failed gesture attempts. |
| 6 | Predicted forecast tooltip (#3) | 🟠 | `SelectionPopoverView` 73/105 against a rewritten `MainChartView`. |
| 7 | Bolus pills IOB/COB (#7) | 🟠 | `TreatmentsStateModel` churned 439. |
| 8 | **COB/IOB projections (#4)** | 🔴 | **Last.** Rewrite the `OpenAPS.swift` patch against the Swift oref pipeline: take `latestCarbDate` from the typed `[CarbsEntry]` upstream now returns, instead of the `fetchAndProcessCarbs` tuple hack. CoreData entities port clean; the plumbing does not. |

**Per-feature discipline**

- One branch per feature, off the new base. Never batch two.
- Build + tests green before starting the next.
- Register every new `.swift` in `project.pbxproj` per the four-section procedure
  in `CLAUDE.md` — creating the file is not enough.
- Run SwiftFormat before committing.

**Extra gate on #8:** it changes what is written to CoreData on every
determination cycle. Verify against a stock upstream build that dosing decisions
are byte-identical with the projection code present vs absent.

---

## 7. Phase 3 / Phase 4

**Phase 3 — unmerged branches**

- `claude/trio-basal-rate-widget-2ikgez` — re-port after Phase 2. Bounded merge
  into upstream's expanded `LiveActivityAttributes` / `DataManager`.
- `feature/modern-home-layout` — **decide, don't port reflexively.** After living
  with upstream's refactor in Phase 1: (a) drop it if upstream's modernization
  covers the intent; (b) re-port the switch into `dashboardContent(_ geo:)` and
  rebuild `modernViewElements` against the new component set; (c) cherry-pick only
  what upstream lacks. `DummyCharts.swift` is gone — whatever used it needs a new
  home.

**Phase 4 — prevent recurrence**

Keep `upstream` as a permanent remote and sync on **every upstream release tag**.
The 8 features here were built across ~10 releases of drift; that is why this is a
re-port instead of a merge.

---

## 8. Runbook

### Done — Linux session, 2026-08-08

No Swift/Xcode toolchain exists in that environment, so Phase 1 steps 1–2 were
completed there and steps 3–5 were left for a Mac.

```bash
git remote add upstream https://github.com/nightscout/Trio
git remote set-url --push upstream DISABLED   # fork safety: never push upstream
git fetch upstream dev
git branch spike/upstream-base upstream/dev   # -> 469562376 (0.8.4.47)
```

`spike/upstream-base` is **local only** — it was deliberately not pushed, since it
is a verbatim copy of `upstream/dev` and is trivially recreated on any machine
with the commands above.

**Submodule pre-flight (all 13 verified):** every URL on `spike/upstream-base`
resolves anonymously, and every pinned commit is fetchable — including the two new
ones, `AccuChekKit` (`940d19dc`) and `EversenseKit` (`b46c45cc`), and the freshly
bumped `OmnipodKit` (`e31a8d1c`). No dangling pins; `git submodule update --init
--recursive` should not stall on a bad reference.

### To do — Mac with Xcode (Phase 1 steps 3–5)

```bash
git fetch upstream
git checkout spike/upstream-base
git submodule update --init --recursive

xed .   # opens Trio.xcworkspace

xcodebuild build-for-testing -workspace Trio.xcworkspace -scheme "Trio Tests" \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'

xcodebuild test-without-building -workspace Trio.xcworkspace -scheme "Trio Tests" \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'
```

Record the result of the gate here before moving to Phase 2:

- [ ] upstream `dev` builds clean
- [ ] test suite green (record failures if any)
- [ ] runs on device with real pump + CGM
- [ ] lived with stock home refactor — Modern layout verdict: _(keep / drop / partial)_
