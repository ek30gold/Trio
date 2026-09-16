# Layer 1 triage results — all 8 features vs v1.0

Completed 2026-09-15. Eight parallel investigations, one per feature, each
checked against the actual v1.0 tree. Every load-bearing claim below was
independently spot-checked by the orchestrator against the source — this is not
a record of what subagents asserted, it's what was verified.

**Outcome: nothing further gets dropped.** All 8 are worth porting. Two got
cheaper than planned, two got subtler.

---

## Verdicts

| # | Feature | Verdict | Dosing-adjacent |
|---|---|---|---|
| 6 | Carb edit transient recompute | **PORT — clean** | **yes** |
| 2 | Favorite foods / meal presets | **PORT** | no |
| 5 | Watch eventual BG | **PORT** | no |
| 9 | Basal rate Live Activity widget | **PORT** | no |
| 3 | Predicted forecast tooltip | **PORT-WITH-REWRITE** (cheaper) | no |
| 8 | Swipe overrides/temp targets | **PORT-WITH-REWRITE** (smaller) | no |
| 7 | Bolus pills IOB/COB | **PORT-WITH-REWRITE** | **yes (narrow)** |
| 1 | Scheduled overrides | **PORT-WITH-REWRITE** | **yes** |

Three require human review before merge per `CLAUDE.md`: **6, 7, 1**.

---

## Per-feature detail

### 6 — Carb edit transient recompute · PORT, clean
`git apply --check` **succeeds with zero conflicts** against v1.0 (verified).
v1.0 still has the bug: `deleteCarbs` unconditionally calls
`determineBasalSync()` (`HistoryStateModel+Deletion/HistoryStateModel+Carbs.swift:38`),
so editing a carb entry fires a full algorithm cycle with COB transiently zero,
broadcasting a wrong `Determination`, then immediately runs a correct one. The
fix threads `skipRecompute: Bool = false` so only the post-creation recompute
runs. v1.0's new `LoopGuard` does *not* cover this — the two calls are
sequential, not concurrent, so the guard never engages.

Files: `Trio/Sources/Modules/History/HistoryStateModel+Deletion/HistoryStateModel+CarbEditing.swift`,
`…/HistoryStateModel+Carbs.swift`. (Note: under a `+Deletion/` subfolder, not
directly under `Modules/History/`.)

**Dosing-adjacent — the transient recompute produces a real, broadcast,
stored `Determination`.** Port first; it validates the pipeline cheaply.

### 2 — Meal presets · PORT
No overlap with upstream's `feat/quick-pick-treatments` (#1336): that surfaces
algorithmically-derived most-used amounts as quick-log pills, reading treatment
history — it has no concept of named dishes, notes, or manual ordering.
Orthogonal; keep both.

`MealPresetStored` is unchanged in v1.0 (verified: still only `carbs`, `dish`,
`fat`, `protein`), so adding optional `note` + `orderPosition` remains a safe
lightweight migration.

**One integration point moved:** the old patch added
`setupMealPresetsArray()` into a `withThrowingTaskGroup`. In v1.0 that setup
split — `setupLastBolus()` is now `setupLastBolusController()` inside an
`await MainActor.run { … }` block (`TreatmentsStateModel.swift:279-283`,
verified). `setupMealPresetsArray()` belongs in that MainActor block, since it's
viewContext-bound.

Unverified, check before editing: `SettingItems.swift`, `FeatureSettingsView.swift`.

### 5 — Watch eventual BG · PORT
Upstream's `feat/watch-app-forecast` (#1306) added forecast *curve/cone* data
(`showForecast`, `forecastConeMin/Max`, `forecastLines`) for a chart overlay —
**not** a scalar eventual-BG readout. Repo-wide grep found no `eventualBG` in
the watch display layer. #1473 and #1450 are unrelated (contact image; bolus
input). All 5 target files exist unmoved; `latestDetermination.eventualBG` is
still valid. Won't `git apply` byte-for-byte (line drift) — reapply by hand.

### 9 — Basal rate Live Activity widget · PORT
Not present in v1.0: neither `LiveActivityItem` enum has a basal case. All 11
touched files exist; upstream did **not** fix the `LiveActitiyAttributes.swift`
typo.

**⚠️ `project.pbxproj` — CLAUDE.md is now partly wrong here.** v1.0 migrated
`LiveActivity/Views` to an Xcode 16 **`PBXFileSystemSynchronizedRootGroup`**
(`DDCEBF412CC1B42500DF4C36`, project.pbxproj:2077, referenced by two targets —
verified). Files dropped into that folder **auto-register; no manual pbxproj
edit**. So `LiveActivityBasalRateView.swift` needs nothing.
`BasalData.swift` is different — it lives under
`Trio/Sources/Services/LiveActivity/Data/`, still a plain `PBXGroup`, and
**does** need the four-section registration (sibling `GlucoseData.swift` has
exactly 4 entries: build file 637, file ref 1718, group 3959, sources 5824 —
verified). Copy `TempTargetData.swift`'s pattern.

**Won't compile as-is:** the patch's `fetchAndMapBasal()` uses a bare `context`;
v1.0's rewritten `DataManager.swift` has no shared context property — each
sibling declares `let context = CoreDataStack.shared.newTaskContext()`.

`TreatmentsStateModel.basal` confirmed dead/write-only in v1.0 — safe to drop.

### 3 — Predicted forecast tooltip · PORT-WITH-REWRITE, **cheaper**
Confirmed non-redundant: `ChartSelectionRow` takes a **non-optional**
`selectedGlucose`, and its only caller gates on finding a real reading within
±150s, so scrubbing past "now" renders nothing at all today.

**The expensive half evaporated.** v1.0 computes all three predicted values
natively; the fork's custom `IOBProjection`/`COBProjection` CoreData entities
(~150 lines of model code) are dropped entirely:
- predicted IOB/COB → `state.iobProjection` / `state.cobProjection`
  (`[ProjectionPoint]`, `HomeStateModel.swift:78-79`), already populated and
  already consumed by `CobIobChart.swift`
- predicted glucose → `state.minForecast`/`maxForecast`; the old midpoint
  logic ports essentially unchanged

Work is now: make `selectedGlucose` optional in `ChartSelectionRow.swift`, add
predicted fields + a `selection: Date` fallback, and teach
`mealPanel()`/`updateChartReadout()` in `HomeRootView+MealPanel.swift` to
resolve a future selection instead of dropping it.

Watch for: projections are `Double`, not `Decimal`; confirm the three values
share a time anchor (`determinationsFromPersistence.first?.deliverAt`) so they
line up at the same future instant.

### 8 — Swipe overrides/temp targets · PORT-WITH-REWRITE, **smaller**
No paging exists in v1.0 (`AdjustmentsRootView.swift` still a plain
`List { switch state.selectedTab }`). The `TabView(.page)` approach remains
correct — do **not** re-derive the three failed `DragGesture` attempts.

Of the three old side-changes:
1. **Split delete-confirmation state → no longer needed.** Upstream converged
   on the same idea independently, more robustly: per-tab optionals
   `overrideToDelete` / `tempTargetToDelete` (`AdjustmentsRootView.swift:19-20`)
   wrapped as composable modifiers using the new `glassActionSheet` API
   (lines 154/168/184 — verified). Already survives both tabs rendering.
2. **`defaultText` / `currentActiveAdjustment` → still needed.** Still computed
   properties switching on `state.selectedTab` (~lines 203, 222).
3. **`.tag(item)` → still needed, and fixes a latent upstream bug.** v1.0 still
   does `.tag(index)` (an `Int`) against a `Tab`-typed selection
   (`AdjustmentsRootView.swift:58-60` — verified). A real type mismatch,
   independent of our feature.

Also re-check `DisableInteractivePopGesture`'s NavigationStack assumption.

### 7 — Bolus pills IOB/COB · PORT-WITH-REWRITE
**Safety question answered clean.** A simulated determination can never be
persisted or enacted: `if !simulation` guards at `OpenAPS.swift:326` and `:357`
skip both `storage.save(iob,…)` and `processDetermination(…)`; `enactDetermination()`
is a separate path simulation never touches (verified).

The one live linkage: `calculateInsulin()` feeds `simulatedDetermination.cob`
into `bolusCalculationManager.handleBolusCalculation`, producing the **displayed**
bolus recommendation a user may accept. Stale simulated COB skews what's shown;
it cannot dose anything by itself. That linkage already exists in v1.0
independent of this port.

v1.0 state: pills still show **input echo** (`state.carbs`/`state.amount`,
`ForecastChart.swift:38-65`), and `mapForecastsFromController()` hardcodes
`iob: 0, cob: 0` (`TreatmentsStateModel.swift:928-929` — verified).
`simulateDetermineBasal(simulatedCarbsAmount:simulatedBolusAmount:simulatedCarbsDate:)`
exists with the expected signature (`APSManager.swift:599`, protocol at `:36`).

**The race moved.** v1.0's `TreatmentsRootView.swift` already calls
`updateForecasts()` directly on carb-debounce and bolus `.onChange`, while the
CoreData sink unconditionally overwrites `simulatedDetermination` with no
`hasPendingEntry` guard and no generation token. So the race is now View-layer
vs StateModel sink, not internal to `updateForecasts`. Port the generation
token + pending guard across **both** call sites, and fix the hardcoded 0/0.

### 1 — Scheduled overrides · PORT-WITH-REWRITE
Port from patch `01b` (the bugfix version), not `01`.

**v1.0 added `AdjustmentManager`** (`Trio/Sources/Services/Adjustments/AdjustmentManager.swift`,
new in v1.0 — verified absent pre-v1.0; registered in `ServiceAssembly`, not
`APSAssembly`). It is now the single writer for *immediate* override/temp-target
activation — remote control, shortcuts and watch all route through it. It has no
concept of a future start time.

**Our `ScheduledOverrideManager` must delegate to it**
(`adjustmentManager.activateOverride(.objectID(id), source: .app)`) rather than
hand-rolling the CoreData transaction, or it silently bypasses the single-writer
invariant #1482 just established — missing side effects, racing with concurrent
remote/watch commands.

**Upstream shipped the bug we already fixed.** Their own
`saveScheduledTempTarget()` still uses a view-layer `Task.sleep` timer
(`AdjustmentsStateModel+Extensions/AdjustmentsStateModel+TempTargets.swift:136`
→ `waitUntilDate` :159 → `Task.sleep` :203 — verified). So: temp-target
scheduling exists natively but broken; **override** scheduling doesn't exist at
all. Extend theirs rather than duplicating it.

CoreData has no `isScheduled` attribute yet — must be added
(lightweight-migration-safe). `APSAssembly`'s registration pattern is unaffected
by #1367 di-hygiene.

**Noise to strip:** `01b`'s `Screen.swift` and `TrioRemoteControl.swift` hunks
are unrelated QA fixes bundled into the same branch — split them out.

---

## Candidates to send upstream

Two bugs this fork already fixed are live in shipped v1.0:
1. The view-layer `Task.sleep` scheduler in `saveScheduledTempTarget()`.
2. `.tag(index)` against a `Tab`-typed Picker selection.

Worth offering upstream once proven here.

## Correction owed to CLAUDE.md

Its "creating a new `.swift` file is not enough — register it in four
`project.pbxproj` sections" rule is no longer universally true. It holds for
plain `PBXGroup` directories, but v1.0 uses Xcode 16 synchronized folders for at
least `LiveActivity/Views` and `Preview Content`, where files auto-register and
a manual edit would be wrong. The rule needs a carve-out.
