import CoreData
import Foundation
import Swinject
import UserNotifications

/// Activates scheduled Overrides whose start time has arrived.
///
/// This deliberately lives outside the view layer. The previous implementation armed an in-process
/// `Task.sleep` timer inside `Adjustments.StateModel`, and re-armed it from that state model's
/// `subscribe()` — which only runs when the Adjustments screen appears. If the app was terminated
/// and relaunched in the background (a CGM reading waking it), nothing re-armed the timer and
/// nothing registered the notification observer, so the Override silently never started and then
/// became unreachable once its start time passed.
///
/// This manager is an app-lifetime service driven by the glucose pulse, so catch-up runs whenever
/// Trio is running at all, regardless of which screen the user is on.
protocol ScheduledOverrideManager {
    /// Activates any scheduled Override that has come due, or drops it if it is too stale.
    func catchUpOnDueScheduledOverrides() async
    /// The same catch-up for scheduled Temp Targets, which had the identical defect.
    func catchUpOnDueScheduledTempTargets() async
}

/// The catch-up policy, kept free of Core Data so it can be tested directly.
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

    private let viewContext = CoreDataStack.shared.persistentContainer.viewContext

    /// How late a scheduled Override may start and still be activated.
    ///
    /// The glucose pulse runs roughly every 5 minutes, so a normal overnight activation lands well
    /// inside this. The window only binds when Trio genuinely was not running — an extended CGM
    /// gap, or the phone being off — which is exactly when starting a dosing change the user has
    /// mentally moved past is the wrong thing to do.
    static let activationGracePeriod: TimeInterval = 15 * 60

    init(resolver: Resolver) {
        injectServices(resolver)
    }

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

    @MainActor private func activate(_ id: NSManagedObjectID, now: Date) async {
        do {
            guard let override = try viewContext.existingObject(with: id) as? OverrideStored,
                  let scheduledStart = override.date else { return }

            let lateness = now.timeIntervalSince(scheduledStart)

            guard case let .activate(trimmed) = decision(for: override, now: now) else {
                await drop(id, now: now, superseded: false)
                return
            }

            await disableActiveOverrides()

            if let trimmed {
                override.duration = NSDecimalNumber(decimal: trimmed)
            }

            override.enabled = true
            override.date = now
            override.isScheduled = false // no longer pending — it has started
            override.isUploadedToNS = false

            guard viewContext.hasChanges else { return }
            try viewContext.save()

            debug(
                .default,
                "\(DebuggingIdentifiers.succeeded) Activated scheduled override '\(override.name ?? "")' " +
                    "\(Int(lateness / 60)) min after its scheduled start"
            )

            Foundation.NotificationCenter.default.post(name: .didUpdateOverrideConfiguration, object: nil)
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
                await notifyMissed(name: name, scheduledStart: scheduledStart)
            }
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to drop stale scheduled override: \(error)"
            )
        }
    }

    /// Disables any currently running Override and records a run entry, so the newly activated
    /// Override does not stack on top of one already in effect.
    @MainActor private func disableActiveOverrides() async {
        do {
            let activeIDs = try await overrideStorage.loadLatestOverrideConfigurations(fetchLimit: 0)
            let active = try activeIDs.compactMap { try viewContext.existingObject(with: $0) as? OverrideStored }
            guard !active.isEmpty else { return }

            if let running = active.first {
                let runEntry = OverrideRunStored(context: viewContext)
                runEntry.id = UUID()
                runEntry.name = running.name
                runEntry.startDate = running.date ?? .distantPast
                runEntry.endDate = Date()
                runEntry.target = NSDecimalNumber(decimal: overrideStorage.calculateTarget(override: running))
                runEntry.override = running
                runEntry.isUploadedToNS = false
            }

            for override in active {
                override.enabled = false
            }

            if viewContext.hasChanges {
                try viewContext.save()
            }
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to disable active overrides during catch-up: \(error)"
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

            await disableActiveTempTargets()

            if let trimmed {
                tempTarget.duration = NSDecimalNumber(decimal: trimmed)
            }

            tempTarget.enabled = true
            tempTarget.date = now
            tempTarget.isScheduled = false
            tempTarget.isUploadedToNS = false

            guard viewContext.hasChanges else { return }
            try viewContext.save()

            debug(
                .default,
                "\(DebuggingIdentifiers.succeeded) Activated scheduled temp target '\(tempTarget.name ?? "")' " +
                    "\(Int(now.timeIntervalSince(scheduledStart) / 60)) min after its scheduled start"
            )

            Foundation.NotificationCenter.default.post(name: .didUpdateTempTargetConfiguration, object: nil)
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
                await notifyMissed(name: name, scheduledStart: scheduledStart)
            }
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to drop stale scheduled temp target: \(error)"
            )
        }
    }

    @MainActor private func disableActiveTempTargets() async {
        do {
            let activeIDs = try await tempTargetStorage.loadLatestTempTargetConfigurations(fetchLimit: 0)
            let active = try activeIDs.compactMap { try viewContext.existingObject(with: $0) as? TempTargetStored }
            guard !active.isEmpty else { return }

            if let running = active.first {
                let runEntry = TempTargetRunStored(context: viewContext)
                runEntry.id = UUID()
                runEntry.name = running.name
                runEntry.startDate = running.date ?? .distantPast
                runEntry.endDate = Date()
                runEntry.target = running.target
                runEntry.tempTarget = running
                runEntry.isUploadedToNS = false
            }

            for tempTarget in active {
                tempTarget.enabled = false
            }

            if viewContext.hasChanges {
                try viewContext.save()
            }
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Failed to disable active temp targets during catch-up: \(error)"
            )
        }
    }

    // MARK: - Notification

    private func notifyMissed(name: String, scheduledStart: Date) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Scheduled Override Did Not Start")
        content.body = String(
            localized: "\(name) was scheduled for \(DateFormatter.localizedString(from: scheduledStart, dateStyle: .none, timeStyle: .short)) but Trio was not running. It has not been started."
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "missedScheduledOverride-\(scheduledStart.timeIntervalSince1970)",
            content: content,
            trigger: nil // deliver immediately
        )

        try? await UNUserNotificationCenter.current().add(request)
    }
}
