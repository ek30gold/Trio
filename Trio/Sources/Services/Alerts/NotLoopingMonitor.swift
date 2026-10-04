import Combine
import Foundation
import LoopKit
import Swinject

/// Escalating watchdog for a stalled loop. On every successful loop the
/// pending alarms are retracted and a fresh ladder is armed: a Time-Sensitive
/// warning at 20, 40, 60, 80 and 100 minutes, then a Critical alarm at 120.
///
/// The whole ladder is armed up front rather than re-armed as each one fires.
/// `Alert.Trigger.delayed(interval:)` becomes a `UNTimeIntervalNotification-
/// Trigger`, so the OS owns every step and the Critical alarm still arrives
/// when iOS has suspended Trio — which is the overnight device-failure case
/// the Critical tier exists for. Re-arming as a chain, or counting loop
/// invocations, would both stop dead the moment the app stops running.
///
/// A loop that recovers at any point retracts the remaining steps, so a brief
/// connectivity drop never reaches Critical.
///
/// The Device Alarms "Alert After" setting (default 20 minutes) moves the
/// first warning: warnings then repeat every 20 minutes strictly before the
/// Critical alarm, which always stays at 120 minutes. A tier override for
/// Not Looping applies only to the Critical alarm; warnings stay
/// Time-Sensitive (see `DeviceAlertsStore.tier(for:)`).
///
/// Replaces the legacy `scheduleMissingLoopNotifiactions` direct-UN path
/// in `BaseUserNotificationsManager`. The alert now flows through
/// `TrioAlertManager` and inherits tier config from Device Alarms
/// (Critical tier by default, user-adjustable).
final class NotLoopingMonitor: Injectable {
    @Injected() private var apsManager: APSManager!
    @Injected() private var trioAlertManager: TrioAlertManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!

    /// Minutes of staleness before the first warning fires, read fresh at
    /// every reschedule so a changed setting applies at the next successful
    /// loop. Backed by `DeviceAlertsStore.notLoopingDelayMinutes` in production.
    private let delayMinutes: () -> Int
    private var lastLoopDate = Date()

    /// Minutes of staleness for each Time-Sensitive warning step at the
    /// default delay. Also the maximum number of warning steps.
    private static let warningMinutes: [Int] = [20, 40, 60, 80, 100]

    /// Spacing between consecutive warning steps.
    private static let warningIntervalMinutes: Int = 20

    /// Minutes of staleness before the alarm escalates to Critical. Two hours
    /// of no automated dosing, which is the window discussed for onset of harm
    /// from undelivered insulin.
    private static let criticalMinutes: Int = 120

    /// Critical escalation. Keeps the bare identifier so existing Critical
    /// tier configuration carries over.
    private static let alertID = Alert.Identifier(
        managerIdentifier: "trio.aps",
        alertIdentifier: "loop.notActive"
    )

    /// One identifier per warning step — a single identifier cannot hold more
    /// than one pending notification, the later `add` would replace the earlier.
    private static func warningID(_ step: Int) -> Alert.Identifier {
        Alert.Identifier(managerIdentifier: "trio.aps", alertIdentifier: "loop.notActive.w\(step)")
    }

    private static var allIDs: [Alert.Identifier] {
        [alertID] + warningMinutes.indices.map { warningID($0 + 1) }
    }

    /// Warning steps for a given first-warning delay: every
    /// `warningIntervalMinutes` from the delay, strictly before
    /// `criticalMinutes`. The default delay of 20 gives `warningMinutes`; a
    /// delay of 120 gives none. Never earlier than the default first step, so
    /// the steps always fit the `warningID(1...5)` identifiers in `allIDs`.
    private static func warningSchedule(firstWarningAfter delay: Int) -> [Int] {
        let first = max(delay, warningMinutes[0])
        return Array(stride(from: first, to: criticalMinutes, by: warningIntervalMinutes))
    }

    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        delayMinutes = { DeviceAlertsStore.shared.notLoopingDelayMinutes }
        injectServices(resolver)
        subscribe(to: apsManager.lastLoopDateSubject.eraseToAnyPublisher())
        broadcaster.register(SnoozeObserver.self, observer: self)
    }

    /// Publisher-only seam for tests: assigns the alert manager directly and
    /// subscribes to a supplied loop-date publisher, avoiding the need to stub
    /// the full `APSManager` protocol.
    init(
        loopDates: AnyPublisher<Date, Never>,
        trioAlertManager: TrioAlertManager,
        delayMinutes: @escaping () -> Int = { DeviceAlertsStore.defaultNotLoopingDelayMinutes }
    ) {
        // Plain stored lets first — assigning the `@Injected` wrapper touches `self`.
        self.delayMinutes = delayMinutes
        self.trioAlertManager = trioAlertManager
        subscribe(to: loopDates)
    }

    private func subscribe(to loopDates: AnyPublisher<Date, Never>) {
        loopDates
            .sink { [weak self] date in
                self?.lastLoopDate = date
                self?.rescheduleAlarm()
            }
            .store(in: &subscriptions)
    }

    private func rescheduleAlarm() {
        // Retract first — clears pending UN, modal timer, and throttler so the
        // next issueAlert isn't blocked by 5-min duplicate suppression.
        for identifier in Self.allIDs {
            trioAlertManager.retractAlert(identifier: identifier)
        }

        // Skip when Trio isn't expected to be auto-enacting: open loop, an
        // active manual temp basal, or a suspended pump. In all three the
        // user has implicitly told Trio "don't loop right now"; a "Not
        // Looping" alarm would just be noise. nil injection (publisher-only
        // test seam) passes so the existing tests still exercise the
        // retract/reschedule plumbing.
        guard settingsManager?.settings.dosingMode.automation != AutomationLevel.off,
              apsManager?.isManualTempBasal != true,
              apsManager?.isSuspended != true
        else { return }

        let now = Date()
        let warnings = Self.warningSchedule(firstWarningAfter: delayMinutes())
        for (index, minutes) in warnings.enumerated() {
            issue(identifier: Self.warningID(index + 1), after: minutes, level: .timeSensitive, now: now)
        }
        issue(identifier: Self.alertID, after: Self.criticalMinutes, level: .critical, now: now)
    }

    /// The catalog decides the interruption level for `trio.aps` alerts, so the
    /// level passed here only matters if the entry is ever removed.
    ///
    /// Steps are measured from the last successful loop, not from `now`, so a
    /// mid-window re-arm keeps the original schedule. A step whose moment has
    /// already passed is skipped rather than fired late.
    private func issue(identifier: Alert.Identifier, after minutes: Int, level: Alert.InterruptionLevel, now: Date) {
        let fireDate = lastLoopDate.addingTimeInterval(TimeInterval(minutes * 60))
        let remaining = fireDate.timeIntervalSince(now)
        guard remaining > 0 else { return }
        let content = Alert.Content(
            title: String(localized: "Trio Not Active"),
            body: String(
                format: String(localized: "Last loop was more than %d min ago"),
                minutes
            ),
            acknowledgeActionButtonLabel: String(localized: "OK")
        )
        let alert = Alert(
            identifier: identifier,
            foregroundContent: content,
            backgroundContent: content,
            trigger: .delayed(interval: remaining),
            interruptionLevel: level,
            sound: .sound(name: "honk.caf")
        )
        trioAlertManager.issueAlert(alert)
    }
}

extension NotLoopingMonitor: SnoozeObserver {
    /// A snooze clears pending non-critical notifications wholesale, which
    /// would drop ladder steps scheduled past the end of the window as well as
    /// the ones inside it. Re-arm from the same anchor; `TrioAlertManager`
    /// drops the steps that fall inside the window and keeps the rest.
    @MainActor func snoozeDidChange(_: Date) {
        rescheduleAlarm()
    }
}
