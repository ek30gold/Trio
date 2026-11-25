import Foundation
import HealthKit
import Swinject
import UIKit
import UserNotifications

/// STAGE 0 — THROWAWAY latency probe for the Exercise Nudge feature.
///
/// Measures how long Apple Watch heart-rate samples take to reach this iPhone through
/// `HKObserverQuery` background delivery, registered at the same point in launch
/// (`TrioApp.loadServices()`) where the production service will live.
///
/// Read-only: it requests heart-rate READ access, writes nothing to HealthKit, and touches no
/// dosing, override, or APS code. It posts one local notification per delivery (with two no-op
/// test actions, to verify that action buttons appear) and writes one log line per delivery
/// under the `HealthKit` log category, prefixed `HRProbe`.
///
/// Delete this file, its `project.pbxproj` entries, and the `loadServices()` call once the
/// latency test is done.
final class HeartRateLatencyProbe {
    static let shared = HeartRateLatencyProbe()

    /// Master switch. Set to `false` to disable the probe without removing it.
    static let isEnabled = true
    /// Post a local notification on each delivery so lag is visible in real time.
    static let postsNotifications = true

    private static let categoryID = "Trio.hrProbe"
    private static let anchorKey = "HeartRateLatencyProbe.anchor"
    /// Only look this far back, so the first run doesn't replay the whole Health history.
    private static let lookback: TimeInterval = 6 * 60 * 60

    private var healthStore: HKHealthStore?
    private var started = false

    // State below is only touched on `stateQueue`.
    private let stateQueue = DispatchQueue(label: "HeartRateLatencyProbe.state")
    private var lastWakeDate: Date?
    private var isInForeground = true
    private var wakeCount = 0
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Start

    func start(resolver: Resolver) {
        guard Self.isEnabled, !started, HKHealthStore.isHealthDataAvailable(),
              let hrType = HKObjectType.quantityType(forIdentifier: .heartRate),
              let store = resolver.resolve(HKHealthStore.self)
        else { return }
        started = true
        healthStore = store

        trackAppState()

        // Delay so BaseUserNotificationsManager's own async category write lands first;
        // both use read-merge-write, but an overlapping write could drop ours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.registerProbeCategory()
        }

        store.requestAuthorization(toShare: nil, read: [hrType]) { [weak self] success, error in
            if let error {
                warning(.healthKit, "HRProbe authorization request failed", error: error)
            }
            // HealthKit never reveals whether READ access was granted; success only means the
            // request was handled. No samples arriving later is the only sign of denial.
            info(.healthKit, "HRProbe authorization request handled: success=\(success)")
            self?.installObserver(for: hrType)
        }
    }

    // MARK: - Observer + background delivery

    private func installObserver(for hrType: HKQuantityType) {
        guard let store = healthStore else { return }

        let query = HKObserverQuery(sampleType: hrType, predicate: nil) { [weak self] _, completionHandler, error in
            let wakeDate = Date()
            if let error {
                warning(.healthKit, "HRProbe observer error", error: error)
                completionHandler()
                return
            }
            guard let self else {
                completionHandler()
                return
            }
            // HealthKit stops waking the app after repeated missing calls, so the
            // completion handler must run on every path.
            self.fetchNewSamples(hrType: hrType, wakeDate: wakeDate) {
                completionHandler()
            }
        }
        store.execute(query)

        store.enableBackgroundDelivery(for: hrType, frequency: .immediate) { success, error in
            if let error {
                warning(.healthKit, "HRProbe enableBackgroundDelivery failed", error: error)
            }
            info(.healthKit, "HRProbe enableBackgroundDelivery(.immediate): success=\(success)")
        }
        info(.healthKit, "HRProbe observer query installed")
    }

    private func fetchNewSamples(hrType: HKQuantityType, wakeDate: Date, completion: @escaping () -> Void) {
        guard let store = healthStore else {
            completion()
            return
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-Self.lookback),
            end: nil,
            options: []
        )

        let query = HKAnchoredObjectQuery(
            type: hrType,
            predicate: predicate,
            anchor: loadAnchor(),
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, error in
            defer { completion() }
            guard let self else { return }

            if let error {
                warning(.healthKit, "HRProbe anchored query failed", error: error)
                return
            }
            if let newAnchor {
                self.saveAnchor(newAnchor)
            }

            let (sinceLastWake, inForeground, wakeNumber) = self.stateQueue.sync { () -> (TimeInterval?, Bool, Int) in
                let since = self.lastWakeDate.map { wakeDate.timeIntervalSince($0) }
                self.lastWakeDate = wakeDate
                self.wakeCount += 1
                return (since, self.isInForeground, self.wakeCount)
            }

            let appState = inForeground ? "fg" : "bg"
            let sinceText = sinceLastWake.map(Self.format) ?? "n/a"
            let quantitySamples = (samples as? [HKQuantitySample]) ?? []

            guard let newest = quantitySamples.max(by: { $0.endDate < $1.endDate }),
                  let oldest = quantitySamples.min(by: { $0.endDate < $1.endDate })
            else {
                info(
                    .healthKit,
                    "HRProbe wake#\(wakeNumber) state=\(appState) newSamples=0 sinceLastWake=\(sinceText)"
                )
                return
            }

            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            let bpm = Int(newest.quantity.doubleValue(for: bpmUnit).rounded())
            let lag = wakeDate.timeIntervalSince(newest.endDate)
            let span = newest.endDate.timeIntervalSince(oldest.endDate)
            let source = newest.sourceRevision.source.name
            let device = newest.device?.name ?? "unknown"

            info(
                .healthKit,
                "HRProbe wake#\(wakeNumber) state=\(appState) newSamples=\(quantitySamples.count) " +
                    "newestLag=\(Self.format(lag)) batchSpan=\(Self.format(span)) bpm=\(bpm) " +
                    "sinceLastWake=\(sinceText) source=\(source) device=\(device) " +
                    "newestEnd=\(ISO8601DateFormatter().string(from: newest.endDate)) " +
                    "wake=\(ISO8601DateFormatter().string(from: wakeDate))"
            )

            if Self.postsNotifications {
                self.postProbeNotification(
                    body: "#\(wakeNumber) \(appState) · \(quantitySamples.count) new · lag \(Self.format(lag)) · " +
                        "span \(Self.format(span)) · \(bpm) bpm"
                )
            }
        }
        store.execute(query)
    }

    // MARK: - Notifications (test only)

    private func registerProbeCategory() {
        let center = UNUserNotificationCenter.current()
        let actions = [
            UNNotificationAction(identifier: "Trio.hrProbe.testA", title: "Probe Test A", options: []),
            UNNotificationAction(identifier: "Trio.hrProbe.testB", title: "Probe Test B", options: [])
        ]
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        center.getNotificationCategories { existing in
            var categories = existing
            categories.update(with: category)
            DispatchQueue.main.async {
                center.setNotificationCategories(categories)
                center.getNotificationCategories { registered in
                    let ids = registered.map(\.identifier).sorted().joined(separator: ",")
                    info(.healthKit, "HRProbe categories after register: \(ids)")
                }
            }
        }
    }

    private func postProbeNotification(body: String) {
        let content = UNMutableNotificationContent()
        content.title = "HR Probe"
        content.body = body
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = Self.categoryID
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "\(Self.categoryID).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                warning(.healthKit, "HRProbe notification failed", error: error)
            }
        }
    }

    // MARK: - App state tracking

    private func trackAppState() {
        let center = NotificationCenter.default
        let background = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stateQueue.async { self?.isInForeground = false }
        }
        let foreground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stateQueue.async { self?.isInForeground = true }
        }
        observers = [background, foreground]

        DispatchQueue.main.async { [weak self] in
            let active = UIApplication.shared.applicationState != .background
            self?.stateQueue.async { self?.isInForeground = active }
        }
    }

    // MARK: - Anchor persistence

    private func loadAnchor() -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: Self.anchorKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.anchorKey)
    }

    // MARK: - Formatting

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let sign = total < 0 ? "-" : ""
        let value = abs(total)
        return value >= 60 ? "\(sign)\(value / 60)m\(value % 60)s" : "\(sign)\(value)s"
    }
}
