import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

/// Tests for scheduled Override activation.
///
/// A scheduled Override is stored as an `OverrideStored` row with `enabled == false`,
/// `isPreset == false`, `isScheduled == true` and `date` set to the intended start time.
///
/// The bug these cover: activation used to be driven by an in-process `Task.sleep` armed from
/// `Adjustments.StateModel.subscribe()`, which only runs when the Adjustments screen appears. If
/// the app was terminated and relaunched in the background, nothing re-armed it, the Override never
/// started, and once its start time passed it was unreachable — the "scheduled overnight, did not
/// fire in the morning" failure.
///
/// Two things fix it, and both are covered here: `isScheduled` makes a pending Override
/// distinguishable from a cancelled one (so catch-up cannot resurrect a cancelled Override), and
/// `fetchDueScheduledOverrides(asOf:)` finds past-due Overrides so an app-lifetime service can act
/// on them.
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

    /// Builds an Override in the shape `EditOverrideForm`'s "Schedule Override" button stores.
    private func makeScheduledOverride(
        name: String,
        activationDate: Date,
        durationMinutes: Decimal = 60,
        indefinite: Bool = false
    ) -> Override {
        Override(
            name: name,
            enabled: false,
            date: activationDate,
            duration: durationMinutes,
            indefinite: indefinite,
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
            uamMinutes: 30,
            isScheduled: true
        )
    }

    private func names(of ids: [NSManagedObjectID]) async throws -> [String] {
        try await testContext.perform {
            try ids.compactMap { id in
                (try testContext.existingObject(with: id) as? OverrideStored)?.name
            }
        }
    }

    // MARK: - Pending vs. due

    @Test("Pending scheduled override is discoverable before its activation time")
    func testPendingScheduledOverrideIsDiscoverable() async throws {
        let activationDate = Date().addingTimeInterval(60 * 60)
        try await storage.storeOverride(override: makeScheduledOverride(
            name: "Pending Override",
            activationDate: activationDate
        ))

        let scheduledIDs = try await storage.fetchScheduledOverrides()
        let foundNames = try await names(of: scheduledIDs)

        #expect(scheduledIDs.count == 1, "A future-dated scheduled override should be listed as pending")
        #expect(foundNames == ["Pending Override"], "Should find the pending override")
    }

    @Test("A pending scheduled override is not yet due")
    func testPendingOverrideIsNotDue() async throws {
        try await storage.storeOverride(override: makeScheduledOverride(
            name: "Pending Override",
            activationDate: Date().addingTimeInterval(60 * 60)
        ))

        let dueIDs = try await storage.fetchDueScheduledOverrides(asOf: Date())

        #expect(dueIDs.isEmpty, "An override scheduled for the future must not be activated early")
    }

    // MARK: - The fix: missed overrides are recoverable

    @Test("Scheduled override missed while the app was not running is found by catch-up")
    func testMissedScheduledOverrideIsFoundByCatchUp() async throws {
        // The app was terminated overnight; this override's start time passed with nothing running.
        let missedActivationDate = Date().addingTimeInterval(-30 * 60)
        try await storage.storeOverride(override: makeScheduledOverride(
            name: "Missed Override",
            activationDate: missedActivationDate
        ))

        // It is correctly no longer "pending"...
        let pendingIDs = try await storage.fetchScheduledOverrides()
        #expect(pendingIDs.isEmpty, "A past-due override is no longer pending")

        // ...but the catch-up query, which has no `date > now` bound, still finds it. Previously
        // nothing could reach it and it was stranded forever.
        let dueIDs = try await storage.fetchDueScheduledOverrides(asOf: Date())
        let dueNames = try await names(of: dueIDs)

        #expect(dueIDs.count == 1, "A missed scheduled override must be recoverable by catch-up")
        #expect(dueNames == ["Missed Override"], "Should find the missed override")
    }

    @Test("Catch-up never resurrects a cancelled override")
    func testCatchUpIgnoresCancelledOverrides() async throws {
        // A cancelled custom override: `enabled == false`, `isPreset == false`, past `date`.
        // Identical to a missed scheduled override in every field except `isScheduled`.
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
            // isScheduled defaults to false
        ))

        try await storage.storeOverride(override: makeScheduledOverride(
            name: "Missed Override",
            activationDate: Date().addingTimeInterval(-30 * 60)
        ))

        let dueIDs = try await storage.fetchDueScheduledOverrides(asOf: Date())
        let dueNames = try await names(of: dueIDs)

        // Without `isScheduled` both rows matched, and catch-up would have re-enabled an override
        // the user had explicitly cancelled — unacceptable for dosing.
        #expect(dueNames == ["Missed Override"], "Only the scheduled override is eligible for catch-up")
    }
}

/// Scheduled Temp Targets had the identical defect, so they get the identical coverage.
@Suite("Scheduled Temp Target Tests", .serialized) struct ScheduledTempTargetTests: Injectable {
    @Injected() var storage: TempTargetsStorage!
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!

    init() async throws {
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()

        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext)
        ])

        resolver = assembler.resolver
        injectServices(resolver)
    }

    private func makeTempTarget(name: String, at date: Date, isScheduled: Bool) -> TempTarget {
        TempTarget(
            name: name,
            createdAt: date,
            targetTop: 120,
            targetBottom: 120,
            duration: 60,
            enteredBy: TempTarget.local,
            reason: TempTarget.custom,
            isPreset: false,
            enabled: false,
            halfBasalTarget: 160,
            isScheduled: isScheduled
        )
    }

    private func names(of ids: [NSManagedObjectID]) async throws -> [String] {
        try await testContext.perform {
            try ids.compactMap { id in
                (try testContext.existingObject(with: id) as? TempTargetStored)?.name
            }
        }
    }

    @Test("Missed scheduled temp target is found by catch-up")
    func testMissedScheduledTempTargetIsFoundByCatchUp() async throws {
        try await storage.storeTempTarget(tempTarget: makeTempTarget(
            name: "Missed TT",
            at: Date().addingTimeInterval(-30 * 60),
            isScheduled: true
        ))

        let pendingIDs = try await storage.fetchScheduledTempTargets()
        #expect(pendingIDs.isEmpty, "A past-due temp target is no longer pending")

        let dueIDs = try await storage.fetchDueScheduledTempTargets(asOf: Date())
        let dueNames = try await names(of: dueIDs)

        #expect(dueNames == ["Missed TT"], "A missed scheduled temp target must be recoverable by catch-up")
    }

    @Test("Catch-up never resurrects a cancelled temp target")
    func testCatchUpIgnoresCancelledTempTargets() async throws {
        try await storage.storeTempTarget(tempTarget: makeTempTarget(
            name: "Cancelled TT",
            at: Date().addingTimeInterval(-45 * 60),
            isScheduled: false
        ))
        try await storage.storeTempTarget(tempTarget: makeTempTarget(
            name: "Missed TT",
            at: Date().addingTimeInterval(-30 * 60),
            isScheduled: true
        ))

        let dueIDs = try await storage.fetchDueScheduledTempTargets(asOf: Date())
        let dueNames = try await names(of: dueIDs)

        #expect(dueNames == ["Missed TT"], "Only the scheduled temp target is eligible for catch-up")
    }
}

/// The catch-up policy itself, exercised without Core Data.
@Suite("Scheduled Override Catch-Up Policy") struct ScheduledOverrideCatchUpTests {
    private let grace: TimeInterval = 15 * 60
    private let now = Date()

    private func decide(lateBy minutes: Double, duration: Decimal = 60, indefinite: Bool = false)
        -> ScheduledOverrideCatchUp.Decision
    {
        ScheduledOverrideCatchUp.decide(
            scheduledStart: now.addingTimeInterval(-minutes * 60),
            now: now,
            durationMinutes: duration,
            indefinite: indefinite,
            grace: grace
        )
    }

    @Test("Activates on time with the full duration intact")
    func testOnTimeActivation() {
        #expect(decide(lateBy: 0) == .activate(trimmedDurationMinutes: 60))
    }

    @Test("Trims the duration so a late start still ends when originally intended")
    func testLateActivationTrimsDuration() {
        // Scheduled 6:00-7:00, started 6:05 → 55 minutes left, still ending at 7:00.
        #expect(decide(lateBy: 5) == .activate(trimmedDurationMinutes: 55))
    }

    @Test("Activates just inside the grace window")
    func testBoundaryInsideGrace() {
        #expect(decide(lateBy: 15) == .activate(trimmedDurationMinutes: 45))
    }

    @Test("Drops an override that is past the grace window")
    func testTooStaleIsDropped() {
        // The overnight-gap case: too long unattended to start a dosing change now.
        #expect(decide(lateBy: 16) == .drop(.tooStale))
        #expect(decide(lateBy: 8 * 60) == .drop(.tooStale))
    }

    @Test("Drops an override whose own window already elapsed")
    func testAlreadyElapsedIsDropped() {
        // A 10-minute override started 12 minutes late has nothing left to run, even though 12
        // minutes is inside the grace window.
        #expect(decide(lateBy: 12, duration: 10) == .drop(.alreadyElapsed))
    }

    @Test("Indefinite overrides activate without trimming")
    func testIndefiniteIsNotTrimmed() {
        #expect(decide(lateBy: 10, duration: 0, indefinite: true) == .activate(trimmedDurationMinutes: nil))
    }

    @Test("An indefinite override past the grace window is still dropped")
    func testIndefiniteStillRespectsGrace() {
        #expect(decide(lateBy: 60, duration: 0, indefinite: true) == .drop(.tooStale))
    }
}
