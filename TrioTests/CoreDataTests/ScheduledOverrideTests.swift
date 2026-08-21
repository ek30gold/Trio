import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

/// Tests covering the persistence layer that scheduled Override activation depends on.
///
/// A scheduled Override is stored by `EditOverrideForm` as a regular `OverrideStored` row with
/// `enabled == false`, `isPreset == false` and `date` set to the future activation time. Nothing
/// in the record marks it as "scheduled" — that state is inferred purely from those three fields.
/// Activation is then driven by an in-process `Task` (`waitUntilDate`) held in
/// `Adjustments.StateModel.scheduledOverrideTasks`, which does not survive app suspension or
/// termination.
///
/// These tests pin down what the storage layer can and cannot recover once that in-process task is
/// gone.
@Suite("Scheduled Override Tests", .serialized) struct ScheduledOverrideTests: Injectable {
    @Injected() var storage: OverrideStorage!
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!

    init() async throws {
        // As we are only using this single test context to initialize our in-memory OverrideStorage
        // we need to perform the Unit Tests serialized
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()

        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext) // Add our test assembly last to override Storage
        ])

        resolver = assembler.resolver
        injectServices(resolver)
    }

    /// Builds an Override in the exact shape `EditOverrideForm`'s "Schedule Override" button stores:
    /// not enabled, not a preset, with `date` carrying the intended activation time.
    private func makeScheduledOverride(name: String, activationDate: Date) -> Override {
        Override(
            name: name,
            enabled: false,
            date: activationDate,
            duration: 60,
            indefinite: false,
            percentage: 130,
            smbIsOff: false,
            isPreset: false,
            id: UUID().uuidString,
            overrideTarget: true,
            target: 110,
            advancedSettings: false,
            isfAndCr: true,
            isf: true,
            cr: true,
            smbIsScheduledOff: false,
            start: 0,
            end: 0,
            smbMinutes: 30,
            uamMinutes: 30
        )
    }

    private func names(of ids: [NSManagedObjectID]) async throws -> [String] {
        try await testContext.perform {
            try ids.compactMap { id in
                (try testContext.existingObject(with: id) as? OverrideStored)?.name
            }
        }
    }

    // MARK: - Control

    @Test("Pending scheduled override is discoverable before its activation time")
    func testPendingScheduledOverrideIsDiscoverable() async throws {
        // Given an override scheduled to start in one hour
        let activationDate = Date().addingTimeInterval(60 * 60)
        try await storage.storeOverride(override: makeScheduledOverride(
            name: "Pending Override",
            activationDate: activationDate
        ))

        // When the app enumerates scheduled overrides (on launch, and to populate the UI list)
        let scheduledIDs = try await storage.fetchScheduledOverrides()

        // Then it is found, so `restartPendingScheduledOverrideTask()` can re-arm its timer
        let foundNames = try await names(of: scheduledIDs)
        #expect(scheduledIDs.count == 1, "A future-dated scheduled override should be discoverable")
        #expect(foundNames == ["Pending Override"], "Should find the pending override")
    }

    // MARK: - The defect

    @Test("Scheduled override whose activation time passed while the app was not running is orphaned")
    func testMissedScheduledOverrideIsOrphaned() async throws {
        // Given an override that was scheduled for 30 minutes ago and never activated, because the
        // in-process `waitUntilDate` task did not survive suspension/termination.
        // The stored `date` is fixed at the intended activation time; only "now" moves past it.
        let missedActivationDate = Date().addingTimeInterval(-30 * 60)
        try await storage.storeOverride(override: makeScheduledOverride(
            name: "Missed Override",
            activationDate: missedActivationDate
        ))

        // When the app relaunches and enumerates scheduled overrides
        let scheduledIDs = try await storage.fetchScheduledOverrides()

        // Then the override has vanished from the scheduled list. `fetchScheduledOverrides()`
        // filters on `date > now`, so a past-due override can never be re-armed by
        // `restartPendingScheduledOverrideTask()` (which additionally guards `scheduledDate > Date()`),
        // and never appears in the UI's scheduled list.
        //
        // The record still exists with `enabled == false`: it is neither active nor pending —
        // it is stranded, and the user is given no indication that it silently failed to start.
        #expect(
            scheduledIDs.isEmpty,
            "Past-due scheduled override is not discoverable — it can never be activated or surfaced to the user"
        )

        // Confirm the row genuinely still exists and is simply unreachable, rather than deleted
        let allStored = try await coreDataStack.fetchEntitiesAsync(
            ofType: OverrideStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "name == %@", "Missed Override"),
            key: "date",
            ascending: false
        ) as? [OverrideStored]

        let (storedCount, storedEnabled) = await testContext.perform {
            (allStored?.count ?? 0, allStored?.first?.enabled ?? true)
        }
        #expect(storedCount == 1, "The stranded override row still exists in Core Data")
        #expect(storedEnabled == false, "The stranded override never became active")
    }

    @Test("A missed scheduled override is still recoverable by exact activation date")
    func testMissedScheduledOverrideIsRecoverableByDate() async throws {
        // Given the same missed scheduled override
        let missedActivationDate = Date().addingTimeInterval(-30 * 60)
        try await storage.storeOverride(override: makeScheduledOverride(
            name: "Missed Override",
            activationDate: missedActivationDate
        ))

        // When looked up by its exact activation date — the path `activateScheduledOverride(for:)`
        // uses, which carries no `date > now` constraint
        let ids = try await storage.fetchScheduledOverride(for: missedActivationDate)

        // Then the record is found. The data is recoverable; the gap is that after a missed window
        // nothing ever calls this — only a user tapping the local notification does.
        let recoveredNames = try await names(of: ids)
        #expect(ids.count == 1, "The missed override is still addressable by its exact activation date")
        #expect(recoveredNames == ["Missed Override"], "Should resolve the missed override")
    }

    // MARK: - Constraint on any fix

    @Test("A missed scheduled override is indistinguishable from a cancelled override")
    func testMissedScheduledOverrideIsIndistinguishableFromCancelledOverride() async throws {
        // Given a cancelled custom override: `cancelOverride(withID:)` sets `enabled = false` and
        // leaves `date` at its original (now past) activation time. It is not a preset.
        try await storage.storeOverride(override: Override(
            name: "Cancelled Override",
            enabled: false,
            date: Date().addingTimeInterval(-45 * 60),
            duration: 60,
            indefinite: false,
            percentage: 80,
            smbIsOff: false,
            isPreset: false,
            id: UUID().uuidString,
            overrideTarget: true,
            target: 120,
            advancedSettings: false,
            isfAndCr: true,
            isf: true,
            cr: true,
            smbIsScheduledOff: false,
            start: 0,
            end: 0,
            smbMinutes: 30,
            uamMinutes: 30
        ))

        // And a scheduled override that was missed
        try await storage.storeOverride(override: makeScheduledOverride(
            name: "Missed Override",
            activationDate: Date().addingTimeInterval(-30 * 60)
        ))

        // When applying the catch-up predicate an obvious fix would reach for —
        // "activate anything disabled, non-preset and past due"
        let catchUpCandidates = try await coreDataStack.fetchEntitiesAsync(
            ofType: OverrideStored.self,
            onContext: testContext,
            predicate: NSPredicate(
                format: "enabled == %@ AND isPreset == %@ AND date <= %@",
                false as NSNumber,
                false as NSNumber,
                Date() as NSDate
            ),
            key: "date",
            ascending: true
        ) as? [OverrideStored]

        let candidateNames = await testContext.perform {
            (catchUpCandidates ?? []).compactMap(\.name).sorted()
        }

        // Then both rows match. `OverrideStored` has no attribute marking a row as
        // "scheduled, not yet activated", so a naive catch-up would resurrect an override the user
        // had explicitly cancelled — unacceptable for dosing. Any fix needs an explicit marker
        // distinguishing a pending scheduled override from a finished or cancelled one.
        #expect(
            candidateNames == ["Cancelled Override", "Missed Override"],
            "Cancelled and missed-scheduled overrides are indistinguishable under the current schema"
        )
    }
}
