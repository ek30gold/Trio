import CoreData
import Foundation
import Swinject
import UserNotifications

/// Activates scheduled Overrides and Temp Targets whose start time has arrived.
///
/// This deliberately lives outside the view layer. Scheduling used to arm an in-process
/// `Task.sleep` timer inside `Adjustments.StateModel` (Temp Targets still had this before this
/// service existed — see `AdjustmentsStateModel+TempTargets.swift`'s former `waitUntilDate`). If the
/// app was terminated and relaunched in the background — a CGM reading waking it — nothing re-armed
/// the timer, so the scheduled row silently never activated and became unreachable once its start
/// time passed.
///
/// This manager is an app-lifetime service driven by the glucose pulse (`FetchGlucoseManager`), so
/// catch-up runs whenever Trio is running at all, regardless of which screen the user is on. It does
/// not perform the activation transaction itself — it hands the decision to `AdjustmentManager`,
/// which is the single writer for override/temp-target activation and cancellation everywhere else
/// in the app (remote control, shortcuts, the watch). Hand-rolling a second Core Data transaction
/// here would race with a command arriving from one of those sources at the same moment.
protocol ScheduledOverrideManager {
    /// Activates any scheduled Override that has come due, or drops it if it is too stale.
    func catchUpOnDueScheduledOverrides() async
    /// The same catch-up for scheduled Temp Targets, which had the identical defect.
    func catchUpOnDueScheduledTempTargets() async
}

/// The catch-up policy, kept free of Core Data and of `AdjustmentManager` so it can be tested
/// directly.
enum ScheduledOverrideCatchUp {
    enum DropReason: Equatable {
        /// Trio was not running for long enough that starting now would be a dosing change at a
        /// time the user never chose.
        case tooStale
        /// The Override's own window has already elapsed, so there is nothing left to run.
        case alreadyElapsed
    }

    enum Decision: Equatable {
        /// Start it. `trimmedDurationMinutes` is nil for an indefinite Override; otherwise it is
        /// the duration shortened so the Override still ends when originally intended.
        case activate(trimmedDurationMinutes: Decimal?)
        case drop(DropReason)

        var isActivate: Bool {
            if case .activate = self { return true }
            return false
        }
    }

    static func decide(
        scheduledStart: Date,
        now: Date,
        durationMinutes: Decimal,
        indefinite: Bool,
        grace: TimeInterval
    ) -> Decision {
        let lateness = max(0, now.timeIntervalSince(scheduledStart))

        guard lateness <= grace else { return .drop(.tooStale) }
        guard !indefinite else { return .activate(trimmedDurationMinutes: nil) }

        let remaining = durationMinutes - Decimal(lateness / 60)
        guard remaining > 0 else { return .drop(.alreadyElapsed) }
        return .activate(trimmedDurationMinutes: remaining)
    }
}

final class BaseScheduledOverrideManager: ScheduledOverrideManager, Injectable {
    @Injected() private var overrideStorage: OverrideStorage!
    @Injected() private var tempTargetStorage: TempTargetsStorage!
    @Injected() private var adjustmentManager: AdjustmentManager!

    private let viewContext = CoreDataStack.shared.persistentContainer.viewContext

    /// How late a scheduled Override or Temp Target may start and still be activated.
    ///
    /// The glucose pulse runs roughly every minute, so a normal overnight activation lands well
    /// inside this. The window only binds when Trio genuinely was not running — an extended CGM
    /// gap, or the phone being off — which is exactly when starting a dosing change the user has
    /// mentally moved past is the wrong thing to do.
    static let activationGracePeriod: TimeInterval = 15 * 60

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    // MARK: - Overrides

    func catchUpOnDueScheduledOverrides() async {
        do {
            let now = Date()
            let dueIDs = try await overrideStorage.fetchDueScheduledOverrides(asOf: now)
            guard !dueIDs.isEmpty else { return }

            // Oldest first. Decide the single winner before mutating anything: if several came due
            // while the app was down, only the most recent one that is still inside the grace
            // window should start — the earlier ones have been superseded.
            let winnerID = try await lastActivatableID(from: dueIDs, now: now)

            for id in dueIDs where id != winnerID {
                await drop(id, now: now)
            }

            if let winnerID {
                await activate(winnerID, now: now)
            }
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to catch up on scheduled overrides: \(error)"
            )
        }
    }

    /// The newest due Override the policy says to start. Nil when every due Override is too stale
    /// or would already have finished.
    @MainActor private func lastActivatableID(from ids: [NSManagedObjectID], now: Date) throws -> NSManagedObjectID? {
        try ids.last { id in
            guard let override = try viewContext.existingObject(with: id) as? OverrideStored else { return false }
            return decision(for: override, now: now).isActivate
        }
    }

    @MainActor private func decision(for override: OverrideStored, now: Date) -> ScheduledOverrideCatchUp.Decision {
        guard let scheduledStart = override.date else { return .drop(.tooStale) }
        return ScheduledOverrideCatchUp.decide(
            scheduledStart: scheduledStart,
            now: now,
            durationMinutes: (override.duration ?? 0).decimalValue,
            indefinite: override.indefinite,
            grace: Self.activationGracePeriod
        )
    }

    /// Trims the duration (if the policy calls for it) and clears `isScheduled` directly on Core
    /// Data, then hands activation itself to `AdjustmentManager` — it ends whatever else is
    /// running (with a run entry), enables this row, timestamps it and uploads to Nightscout.
    /// `AdjustmentManager` re-fetches the row by `objectID` on its own context, so this save must
    /// commit before it is called, or it would activate with the untrimmed duration.
    @MainActor private func activate(_ id: NSManagedObjectID, now: Date) async {
        do {
            guard let override = try viewContext.existingObject(with: id) as? OverrideStored,
                  let scheduledStart = override.date else { return }

            guard case let .activate(trimmed) = decision(for: override, now: now) else {
                await drop(id, now: now)
                return
            }

            let name = override.name ?? ""
            let lateness = now.timeIntervalSince(scheduledStart)

            if let trimmed {
                override.duration = NSDecimalNumber(decimal: trimmed)
            }
            override.isScheduled = false // no longer pending — activation is about to start it

            if viewContext.hasChanges {
                try viewContext.save()
            }

            // `AdjustmentManager` ends whatever else is running (with a run entry), enables this
            // row, timestamps it and uploads to Nightscout — the full sequence every other
            // activation path in the app goes through.
            try await adjustmentManager.activateOverride(.objectID(id), source: .scheduled)

            debug(
                .default,
                "\(DebuggingIdentifiers.succeeded) Activated scheduled override '\(name)' " +
                    "\(Int(lateness / 60)) min after its scheduled start"
            )
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to activate due scheduled override: \(error)"
            )
        }
    }

    /// Clears the pending flag without starting the Override, and tells the user when it was
    /// genuinely missed. Silence is what made the original bug invisible, so a missed Override
    /// always notifies; one merely superseded by a newer Override that did start does not.
    @MainActor private func drop(_ id: NSManagedObjectID, now: Date) async {
        do {
            guard let override = try viewContext.existingObject(with: id) as? OverrideStored,
                  let scheduledStart = override.date else { return }

            let name = override.name ?? String(localized: "Custom Override")
            // An Override the policy would have started, but which a newer due Override replaced.
            let wasSuperseded = decision(for: override, now: now).isActivate

            override.isScheduled = false

            if viewContext.hasChanges {
                try viewContext.save()
            }

            debug(
                .default,
                "\(DebuggingIdentifiers.inProgress) Skipped scheduled override '\(name)' — " +
                    "\(Int(now.timeIntervalSince(scheduledStart) / 60)) min late, superseded: \(wasSuperseded)"
            )

            if !wasSuperseded {
                await notifyMissed(
                    title: String(localized: "Scheduled Override Did Not Start"),
                    name: name,
                    scheduledStart: scheduledStart
                )
            }
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to drop stale scheduled override: \(error)"
            )
        }
    }

    // MARK: - Temp Targets

    func catchUpOnDueScheduledTempTargets() async {
        do {
            let now = Date()
            let dueIDs = try await tempTargetStorage.fetchDueScheduledTempTargets(asOf: now)
            guard !dueIDs.isEmpty else { return }

            let winnerID = try await lastActivatableTempTargetID(from: dueIDs, now: now)

            for id in dueIDs where id != winnerID {
                await dropTempTarget(id, now: now)
            }

            if let winnerID {
                await activateTempTarget(winnerID, now: now)
            }
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to catch up on scheduled temp targets: \(error)"
            )
        }
    }

    @MainActor private func lastActivatableTempTargetID(
        from ids: [NSManagedObjectID],
        now: Date
    ) throws -> NSManagedObjectID? {
        try ids.last { id in
            guard let tempTarget = try viewContext.existingObject(with: id) as? TempTargetStored else { return false }
            return decision(for: tempTarget, now: now).isActivate
        }
    }

    @MainActor private func decision(for tempTarget: TempTargetStored, now: Date) -> ScheduledOverrideCatchUp.Decision {
        guard let scheduledStart = tempTarget.date else { return .drop(.tooStale) }
        return ScheduledOverrideCatchUp.decide(
            scheduledStart: scheduledStart,
            now: now,
            durationMinutes: (tempTarget.duration ?? 0).decimalValue,
            indefinite: false, // Temp Targets always carry a duration
            grace: Self.activationGracePeriod
        )
    }

    @MainActor private func activateTempTarget(_ id: NSManagedObjectID, now: Date) async {
        do {
            guard let tempTarget = try viewContext.existingObject(with: id) as? TempTargetStored,
                  let scheduledStart = tempTarget.date else { return }

            guard case let .activate(trimmed) = decision(for: tempTarget, now: now) else {
                await dropTempTarget(id, now: now)
                return
            }

            let name = tempTarget.name ?? ""
            let lateness = now.timeIntervalSince(scheduledStart)

            if let trimmed {
                tempTarget.duration = NSDecimalNumber(decimal: trimmed)
            }
            tempTarget.isScheduled = false

            if viewContext.hasChanges {
                try viewContext.save()
            }

            try await adjustmentManager.activateTempTarget(.objectID(id), source: .scheduled)

            debug(
                .default,
                "\(DebuggingIdentifiers.succeeded) Activated scheduled temp target '\(name)' " +
                    "\(Int(lateness / 60)) min after its scheduled start"
            )
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to activate due scheduled temp target: \(error)"
            )
        }
    }

    @MainActor private func dropTempTarget(_ id: NSManagedObjectID, now: Date) async {
        do {
            guard let tempTarget = try viewContext.existingObject(with: id) as? TempTargetStored,
                  let scheduledStart = tempTarget.date else { return }

            let name = tempTarget.name ?? String(localized: "Temp Target")
            let wasSuperseded = decision(for: tempTarget, now: now).isActivate

            tempTarget.isScheduled = false

            if viewContext.hasChanges {
                try viewContext.save()
            }

            if !wasSuperseded {
                await notifyMissed(
                    title: String(localized: "Scheduled Temp Target Did Not Start"),
                    name: name,
                    scheduledStart: scheduledStart
                )
            }
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to drop stale scheduled temp target: \(error)"
            )
        }
    }

    // MARK: - Notification

    private func notifyMissed(title: String, name: String, scheduledStart: Date) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(
            localized: "\(name) was scheduled for \(DateFormatter.localizedString(from: scheduledStart, dateStyle: .none, timeStyle: .short)) but Trio was not running. It has not been started."
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "missedScheduledAdjustment-\(scheduledStart.timeIntervalSince1970)",
            content: content,
            trigger: nil // deliver immediately
        )

        try? await UNUserNotificationCenter.current().add(request)
    }
}
