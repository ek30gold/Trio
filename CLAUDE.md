# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Trio

Trio is an open-source automated insulin delivery (AID) system for iOS, built on the OpenAPS algorithm. It manages insulin dosing by integrating with Bluetooth insulin pumps and continuous glucose monitors (CGMs). This is safety-critical medical software — correctness matters above all else.

## Build & Test

**Open in Xcode:**
```
xed .
```
(Opens `Trio.xcworkspace` — always use the workspace, not the `.xcodeproj` directly.)

**Run unit tests (CLI):**
```bash
xcodebuild build-for-testing -workspace Trio.xcworkspace -scheme "Trio Tests" \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'

xcodebuild test-without-building -workspace Trio.xcworkspace -scheme "Trio Tests" \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'
```

**Format code before committing** (SwiftFormat is configured via `BuildTools/Package.swift`):
```bash
swift run --package-path BuildTools swiftformat .
```

**CI/CD:** GitHub Actions workflows in `.github/workflows/`. `build_trio.yml` builds via Fastlane (`bundle exec fastlane build_trio`). `unit_tests.yml` runs the test suite automatically on PRs.

**App version and bundle ID** are set in `Config.xcconfig`.

## Git Workflow — Critical

This is safety-critical software. Trust in reported state must be verifiable, not assumed.

- **Never report a commit or push as successful without verifying it.** After `git commit`, run `git log --oneline -1` and paste the actual hash. After `git push`, the command must return an explicit success message (not just exit cleanly) — confirm with `git log origin/<branch> --oneline -1` and check it matches local HEAD.
- **A `git rebase` that reports "patch already upstream" or "dropping commit" is NOT a push confirmation.** It only means the local commit was redundant against whatever the remote currently is — verify the remote separately.
- **If a push is rejected, stop and report the rejection.** Do not silently rebase-and-retry in a loop. Surface the conflict.
- **When asked to edit files in a session, do not commit or push unless explicitly asked.** Default to edits-only; the human will verify and commit themselves for anything touching dosing-adjacent code.
- **Creating a new `.swift` file is not enough on its own.** Writing a new file to disk and committing it to git does NOT add it to the Xcode build target. It must also be registered in `Trio.xcodeproj/project.pbxproj` (in the `PBXBuildFile`, `PBXFileReference`, `PBXGroup`, and `PBXSourcesBuildPhase` sections), or the build will fail with "cannot find 'X' in scope" even though the file clearly exists and `grep`/`git log` checks pass. When creating a new file:
  1. Find an existing sibling file in the same folder that is known to build correctly, and identify its exact lines in all four `project.pbxproj` sections above.
  2. Generate two new unique 24-character hex UUIDs (one for `PBXFileReference`, one for `PBXBuildFile`) and confirm they don't already exist in the file.
  3. Duplicate the sibling's four lines exactly, swapping in the new UUIDs and filename only.
  4. Verify with `git diff --stat` and full `git diff` on `project.pbxproj` that the change is exactly 4 added lines with nothing removed or altered elsewhere, before committing.
  5. Do not use a plist validator (e.g. Python's `plistlib`) to sanity-check `project.pbxproj` — it will report the file as invalid regardless of correctness, because `.pbxproj` uses the legacy NeXTSTEP/ASCII plist dialect, not XML or binary plist. This is a known false alarm, not a real signal.
- **Verify remote sync before every build, not just before pushing.** Work happens across multiple devices/environments (e.g. a PC and a separate phone/Claude Code mobile session) on the same branches. Before triggering any build, always run `git fetch && git status` first:
  - If local is **ahead** of origin → push before building, or the build won't contain that work.
  - If local is **behind** → pull/rebase before building, or the build will be missing changes made elsewhere.
  - If **diverged** → stop, do not build, reconcile via rebase first (check for conflicts, don't assume which side is correct).
  - Only build once `git status` confirms the branch is up to date with its remote. A build that "still has the bug" may simply be missing a fix that was already correctly committed on a different device — check sync state before re-debugging.

## Before Implementing

For any non-trivial change, read the relevant files in full first and report findings before writing code — especially variable names, existing patterns (e.g. dictionary vs. single-task state, `orderPosition` conventions), and whether a similar feature already exists elsewhere in the codebase. Do not assume a prior session's description of "what was already built" is accurate — verify directly against the current file contents.

## Architecture

### Module Pattern (MVVM)

Every feature lives in `Trio/Sources/Modules/<FeatureName>/` and follows this structure:
- `<Feature>StateModel.swift` — `@Observable` class holding UI state, conforms to `BaseStateModel`
- `<Feature>Provider.swift` — Protocol + `Base<Feature>Provider` class for business logic and data access
- `<Feature>View.swift` — SwiftUI view, receives state model via DI

`BaseStateModel` provides `subscribeSetting()` helpers and access to injected services. Providers access storage and services through the Swinject resolver.

**Note:** Some modules may contain orphaned/dead code from prior refactors (unreferenced views, types with no backing CoreData entity). Confirm a module is actually reachable from the UI (check `Screen.swift` and navigation call sites) before assuming it's the active implementation.

### Dependency Injection (Swinject)

Services are registered in `Trio/Sources/Assemblies/`:
- `StorageAssembly` — CoreData stack, file storage, keychain
- `APSAssembly` — `APSManager`, `DeviceDataManager`, pump/CGM managers
- `ServiceAssembly` — notifications, calendar, telemetry, watch manager
- `NetworkAssembly` — HTTP client, Nightscout, Tidepool
- `SecurityAssembly` — encryption

Use `resolver.resolve(ServiceProtocol.self)` to inject. The resolver is thread-safe via `LockedResolver`.

### Core Loop (APS)

`APSManager` (`Trio/Sources/APS/`) is the heart of the app. Its `heartbeat()` triggers each algorithm cycle:

1. Fetch glucose → `FetchGlucoseManager`
2. Fetch pump state → `DeviceDataManager`
3. Run OpenAPS algorithm → `OpenAPS.determineBasal()`
4. Store determination in CoreData (`DeterminationStorage`)
5. Publish result via Combine (`determinationSubject`)
6. `HomeStateModel` subscribes and updates the UI
7. `WatchManager` broadcasts to companion apps (throttled — see `Services/WatchManager/FLOW_DIAGRAM.md`)

### Data Persistence

Three layers, each with a clear purpose:
- **CoreData** (`Model/TrioCoreDataPersistentContainer.xcdatamodeld`): Main persistent store. Use `viewContext` for reads on the main thread; `privateContext` for background writes.
  - **Migrations:** The CoreData model has a single (unversioned) `.xcdatamodel`. Lightweight migration is enabled (`shouldMigrateStoreAutomatically` / `shouldInferMappingModelAutomatically` both `true` in `CoreDataStack.swift`), so adding new *optional* attributes with default values is safe without a model version bump. Renaming or removing attributes, or adding non-optional attributes without defaults, requires more care.
- **File Storage** (`Services/Storage/`): JSON-serialized `Codable` structs via `FileStorage` protocol. Used for OpenAPS state files (glucose history, pump history, meal data, determinations).
- **Keychain** (`Services/Storage/BaseKeychain`): Credentials and secrets only.

Settings are persisted via `SettingsManager` using the `@Persisted` property wrapper (`TrioSettings`, `Preferences`).

### Navigation

`Router/` defines a `Screen` enum with all app screens. `BaseRouter` handles `push`, `present`, and `dismiss`. Each module declares its own `Router` protocol for type-safe navigation.

### Reactive State

Combine is used throughout. Key patterns:
- `CurrentValueSubject` and `PassthroughSubject` for emitting events
- `.throttle(for: .seconds(10), latest: false)` on high-frequency data (e.g., Watch updates)
- `@Observable` (Swift 5.9 macro) on StateModels for SwiftUI binding

## Key Conventions

**Localization:** All user-facing strings must use the localization mechanism already in the app. English source strings only — translations go through Crowdin. Do not hard-code display strings.

**Formatting:** Run SwiftFormat before committing. Do not make formatting-only changes to files you aren't otherwise modifying.

**Pull requests:** Keep PRs small and focused. Branch from `dev`. Use `fix/`, `feature/`, or `refactor/` prefixes. AI-generated contributions must be fully understood and reviewed by the author — do not submit vibe-coded PRs.

**Adding a new feature module:** Follow the existing StateModel + Provider + View pattern. Register new services in the appropriate `Assembly` file. Add any new settings screen to the Settings search index (see recent commits for examples).

## Multi-Target Structure

- **Trio** — main iOS app
- **Trio Watch App Extension** — watchOS companion
- **Trio Watch Complication** — watchOS widget/complication
- **LiveActivity** — iOS 16.2+ Lock Screen widget
- **TrioTests** — unit test target
- **Trio Watch App Tests** — watch test target

Pump and CGM drivers (OmniBLE, DanaKit, LibreTransmitter, etc.) are git submodules integrated via the workspace.
