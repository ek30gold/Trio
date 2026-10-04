import Combine
import Foundation
import LoopKit
import Testing
import UserNotifications

@testable import Trio

/// Records `issueAlert` / `retractAlert` calls in order so tests can assert
/// the retract-then-issue re-arm semantics of `NotLoopingMonitor`. Every
/// other `TrioAlertManager` member is a no-op stub.
final class SpyAlertManager: TrioAlertManager {
    enum Call: Equatable {
        case retract(Alert.Identifier)
        case issue(Alert)
    }

    private(set) var callLog: [Call] = []
    private(set) var issuedAlerts: [Alert] = []
    private(set) var retractedIdentifiers: [Alert.Identifier] = []

    func issueAlert(_ alert: Alert) {
        callLog.append(.issue(alert))
        issuedAlerts.append(alert)
    }

    func retractAlert(identifier: Alert.Identifier) {
        callLog.append(.retract(identifier))
        retractedIdentifiers.append(identifier)
    }

    // MARK: - No-op stubs

    func register(responder _: AlertResponder, for _: String) {}
    func register(soundVendor _: AlertSoundVendor, for _: String) {}
    func unregister(managerIdentifier _: String) {}

    func handleAcknowledgement(identifier _: Alert.Identifier) {}
    func handleNotificationResponse(_: UNNotificationResponse) {}
    func acknowledgeAllOutstanding() {}
    func replayUnacknowledgedAlerts() {}
    @MainActor func applySnooze(for _: TimeInterval) async {}
    func clearPendingNonCriticalNotifications() {}

    var muter: AlertMuter { AlertMuter() }
    let modalScheduler = TrioModalAlertScheduler()

    func soundURL(for _: Alert) -> URL? { nil }
}

@Suite("Trio Alerts: NotLoopingMonitor") struct NotLoopingMonitorTests {
    /// Reconstructed locally from the private statics in the source.
    private let criticalID = Alert.Identifier(
        managerIdentifier: "trio.aps",
        alertIdentifier: "loop.notActive"
    )
    private func warningID(_ step: Int) -> Alert.Identifier {
        Alert.Identifier(managerIdentifier: "trio.aps", alertIdentifier: "loop.notActive.w\(step)")
    }

    /// Steps are anchored to the last loop date, so the armed interval is a
    /// few milliseconds short of the nominal value by the time it is built.
    private func expectDelay(_ trigger: Alert.Trigger, _ minutes: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case let .delayed(interval) = trigger else {
            Issue.record("expected a delayed trigger, got \(trigger)", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(interval - TimeInterval(minutes * 60)) < 5, sourceLocation: sourceLocation)
    }

    private func armLadder() -> SpyAlertManager {
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(loopDates: subject.eraseToAnyPublisher(), trioAlertManager: spy)
        subject.send(Date())
        _ = monitor // retain through the synchronous send
        return spy
    }

    @Test("A loop success arms five warnings and one critical") func armsFullLadder() {
        let spy = armLadder()
        #expect(spy.issuedAlerts.count == 6)

        let warnings = spy.issuedAlerts.filter { $0.identifier != criticalID }
        #expect(warnings.count == 5)
        for (index, minutes) in [20, 40, 60, 80, 100].enumerated() {
            let alert = warnings[index]
            #expect(alert.identifier == warningID(index + 1))
            expectDelay(alert.trigger, minutes)
            #expect(alert.interruptionLevel == .timeSensitive)
        }
    }

    @Test("The sixth step is critical at 120 minutes") func criticalStepAtTwoHours() {
        let spy = armLadder()
        guard let critical = spy.issuedAlerts.first(where: { $0.identifier == criticalID }) else {
            Issue.record("expected a critical escalation alert")
            return
        }
        expectDelay(critical.trigger, 120)
        #expect(critical.interruptionLevel == .critical)
    }

    @Test("Every step is retracted before anything is re-armed") func retractsWholeLadderFirst() {
        let spy = armLadder()
        let firstIssue = spy.callLog.firstIndex { if case .issue = $0 { return true }
            return false }
        let lastRetract = spy.callLog.lastIndex { if case .retract = $0 { return true }
            return false }
        guard let firstIssue, let lastRetract else {
            Issue.record("expected both retracts and issues")
            return
        }
        #expect(lastRetract < firstIssue)
        #expect(spy.retractedIdentifiers.count == 6)
        #expect(Set(spy.retractedIdentifiers) == Set([criticalID] + (1 ... 5).map(warningID)))
    }

    @Test("A recovered loop re-arms the whole ladder again") func reArmsOnEachSuccess() {
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(loopDates: subject.eraseToAnyPublisher(), trioAlertManager: spy)

        subject.send(Date())
        subject.send(Date())

        #expect(spy.issuedAlerts.count == 12)
        #expect(spy.retractedIdentifiers.count == 12)
        _ = monitor
    }

    @Test("Warning identifiers resolve to the Time-Sensitive tier") func warningsAreCatalogedTimeSensitive() {
        for step in 1 ... 5 {
            guard let entry = AlertCatalogRegistry.lookup(warningID(step)) else {
                Issue.record("warning step \(step) has no catalog entry")
                return
            }
            #expect(entry.interruptionLevel == .timeSensitive)
            #expect(entry.concept == .notLooping)
        }
        #expect(AlertCatalogRegistry.lookup(criticalID)?.interruptionLevel == .critical)
    }

    @Test("Every step is delayed, never immediate") func allStepsDelayed() {
        for alert in armLadder().issuedAlerts {
            #expect(alert.trigger != .immediate)
        }
    }

    /// Arms the ladder once with a fixed first-warning delay.
    private func armLadder(delay: Int) -> SpyAlertManager {
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(
            loopDates: subject.eraseToAnyPublisher(),
            trioAlertManager: spy,
            delayMinutes: { delay }
        )
        subject.send(Date())
        _ = monitor
        return spy
    }

    /// Asserts the warnings are `w1…wN` at `warningMinutes`, Time-Sensitive,
    /// and the last issued step is the Critical alarm at 120 minutes.
    private func expectSchedule(
        _ spy: SpyAlertManager,
        warningMinutes: [Int],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(spy.issuedAlerts.count == warningMinutes.count + 1, sourceLocation: sourceLocation)
        let warnings = spy.issuedAlerts.filter { $0.identifier != criticalID }
        #expect(warnings.count == warningMinutes.count, sourceLocation: sourceLocation)
        for (index, minutes) in warningMinutes.enumerated() where index < warnings.count {
            let alert = warnings[index]
            #expect(alert.identifier == warningID(index + 1), sourceLocation: sourceLocation)
            expectDelay(alert.trigger, minutes, sourceLocation: sourceLocation)
            #expect(alert.interruptionLevel == .timeSensitive, sourceLocation: sourceLocation)
            #expect(alert.backgroundContent.body.contains("\(minutes)"), sourceLocation: sourceLocation)
        }
        guard let critical = spy.issuedAlerts.last, critical.identifier == criticalID else {
            Issue.record("expected the critical alarm to be armed last", sourceLocation: sourceLocation)
            return
        }
        expectDelay(critical.trigger, 120, sourceLocation: sourceLocation)
        #expect(critical.interruptionLevel == .critical, sourceLocation: sourceLocation)
        // Unused step identifiers are still retracted, so no orphan can linger.
        #expect(
            Set(spy.retractedIdentifiers) == Set([criticalID] + (1 ... 5).map(warningID)),
            sourceLocation: sourceLocation
        )
    }

    @Test("Default delay of 20 gives the full ladder") func defaultDelayGivesFullLadder() {
        expectSchedule(armLadder(delay: 20), warningMinutes: [20, 40, 60, 80, 100])
    }

    @Test("Custom delay moves the first warning; critical stays at 120")
    func customDelayMinutesDrivesTriggerAndBody() {
        expectSchedule(armLadder(delay: 50), warningMinutes: [50, 70, 90, 110])
    }

    @Test("Delay of 110 leaves one warning before the critical") func delayOneTenGivesSingleWarning() {
        expectSchedule(armLadder(delay: 110), warningMinutes: [110])
    }

    @Test("Delay of 120 arms only the critical") func delayOneTwentyGivesCriticalOnly() {
        expectSchedule(armLadder(delay: 120), warningMinutes: [])
    }

    @Test("delayMinutes closure is re-read on every reschedule")
    func delayMinutesIsReReadOnEveryReschedule() {
        final class Box { var value = 20 }
        let box = Box()
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(
            loopDates: subject.eraseToAnyPublisher(),
            trioAlertManager: spy,
            delayMinutes: { box.value }
        )

        subject.send(Date())
        #expect(spy.issuedAlerts.count == 6)
        box.value = 90
        subject.send(Date())

        // Second arming: warnings at 90 and 110, then the critical at 120.
        let second = Array(spy.issuedAlerts.dropFirst(6))
        #expect(second.count == 3)
        guard second.count == 3 else { return }
        #expect(second[0].identifier == warningID(1))
        expectDelay(second[0].trigger, 90)
        #expect(second[1].identifier == warningID(2))
        expectDelay(second[1].trigger, 110)
        #expect(second[2].identifier == criticalID)
        expectDelay(second[2].trigger, 120)
        // Every step, including the now-unused w3…w5, retracted on both armings.
        #expect(spy.retractedIdentifiers.count == 12)

        _ = monitor
    }
}
