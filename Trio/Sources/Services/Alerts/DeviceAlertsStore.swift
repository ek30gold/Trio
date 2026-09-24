import Combine
import Foundation
import LoopKit

/// Catalog concepts whose tier the user may move between Critical,
/// Time-Sensitive and Normal. Trio-status alerts only — pump hardware
/// alarms (occlusion, reservoir empty, fault, battery empty) are
/// deliberately absent and always stay at their catalog tier.
enum AdjustableAlert: String, CaseIterable, Codable, Identifiable {
    case notLooping
    case glucoseDataStale
    case algorithmError

    var id: String { rawValue }

    init?(concept: Alert.CatalogConcept) {
        switch concept {
        case .notLooping: self = .notLooping
        case .glucoseDataStale: self = .glucoseDataStale
        case .algorithmError: self = .algorithmError
        default: return nil
        }
    }

    var concept: Alert.CatalogConcept {
        switch self {
        case .notLooping: return .notLooping
        case .glucoseDataStale: return .glucoseDataStale
        case .algorithmError: return .algorithmError
        }
    }
}

/// Persists a flat list of `[DeviceAlertSeverityConfig]` to `UserDefaults`.
/// Multiple configs per severity tier are allowed — each with its own
/// `activeOption` so users can vary behavior between day and night.
///
/// Seeds three default configs (one per tier, all `activeOption: .always`)
/// on first launch so every severity has a baseline that always matches.
///
/// Also stores per-alert tier overrides for `AdjustableAlert`s and the
/// Not Looping alarm delay.
final class DeviceAlertsStore: ObservableObject {
    static let shared = DeviceAlertsStore()

    @Published var configs: [DeviceAlertSeverityConfig]
    /// Per-tier snooze expirations keyed by `DeviceAlertSeverity.rawValue`.
    @Published var tierSnoozes: [String: Date]
    /// User-chosen tier per `AdjustableAlert.rawValue`. Absent key = catalog default.
    @Published private(set) var tierOverrides: [String: DeviceAlertSeverity]
    /// Minutes without a successful loop before the Not Looping alarm fires.
    @Published private(set) var notLoopingDelayMinutes: Int

    static let notLoopingDelayOptions: [Int] = [20, 30, 45, 60, 90, 120]
    static let defaultNotLoopingDelayMinutes = 20

    private let defaults: UserDefaults
    private let configsKey: String
    private let snoozesKey: String
    private let overridesKey: String
    private let delayKey: String

    private var subscriptions = Set<AnyCancellable>()

    init(
        defaults: UserDefaults = .standard,
        configsKey: String = "trio.deviceAlertSeverityConfigs.v1",
        snoozesKey: String = "trio.deviceAlertTierSnoozes.v1",
        overridesKey: String = "trio.deviceAlertTierOverrides.v1",
        delayKey: String = "trio.notLoopingDelayMinutes.v1"
    ) {
        self.defaults = defaults
        self.configsKey = configsKey
        self.snoozesKey = snoozesKey
        self.overridesKey = overridesKey
        self.delayKey = delayKey
        let loaded = Self.decode([DeviceAlertSeverityConfig].self, from: defaults, key: configsKey) ?? []
        var seeded = loaded
        for severity in DeviceAlertSeverity.allCases
            where !seeded.contains(where: { $0.severity == severity && $0.activeOption == .always })
        {
            seeded.append(DeviceAlertSeverityConfig(severity: severity, activeOption: .always))
        }
        configs = Self.sorted(seeded)
        let snoozes = Self.decode([String: Date].self, from: defaults, key: snoozesKey) ?? [:]
        tierSnoozes = snoozes.filter { $0.value > Date() }
        // Drop keys that aren't adjustable alerts so stale or foreign data
        // can never re-tier a locked pump alarm.
        let overrides = Self.decode([String: DeviceAlertSeverity].self, from: defaults, key: overridesKey) ?? [:]
        tierOverrides = overrides.filter { AdjustableAlert(rawValue: $0.key) != nil }
        let delay = Self.decode(Int.self, from: defaults, key: delayKey)
        if let delay, Self.notLoopingDelayOptions.contains(delay) {
            notLoopingDelayMinutes = delay
        } else {
            notLoopingDelayMinutes = Self.defaultNotLoopingDelayMinutes
        }
        bind()
    }

    // MARK: - Per-tier snooze

    func snoozeTier(_ tier: DeviceAlertSeverity, until: Date) {
        if until > Date() {
            tierSnoozes[tier.rawValue] = until
        } else {
            tierSnoozes.removeValue(forKey: tier.rawValue)
        }
    }

    func isTierSnoozed(_ tier: DeviceAlertSeverity, at date: Date) -> Bool {
        guard let until = tierSnoozes[tier.rawValue] else { return false }
        return until > date
    }

    private func bind() {
        $configs
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] value in self?.encode(value, to: self?.configsKey ?? "") }
            .store(in: &subscriptions)
        $tierSnoozes
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] value in self?.encode(value, to: self?.snoozesKey ?? "") }
            .store(in: &subscriptions)
        $tierOverrides
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] value in self?.encode(value, to: self?.overridesKey ?? "") }
            .store(in: &subscriptions)
        $notLoopingDelayMinutes
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] value in self?.encode(value, to: self?.delayKey ?? "") }
            .store(in: &subscriptions)
    }

    // MARK: - Per-alert tier overrides

    /// Catalog default tier for an adjustable alert (first matching registry entry).
    func defaultTier(for alert: AdjustableAlert) -> DeviceAlertSeverity {
        // Fall back to .critical if the entry is somehow missing — the safest tier.
        guard let entry = AlertCatalogRegistry.entries.first(where: { $0.concept == alert.concept }),
              let tier = DeviceAlertSeverity(level: entry.interruptionLevel)
        else { return .critical }
        return tier
    }

    /// Effective tier: user override if set, else catalog default.
    func tier(for alert: AdjustableAlert) -> DeviceAlertSeverity {
        tierOverrides[alert.rawValue] ?? defaultTier(for: alert)
    }

    /// Effective tier for any catalog entry. Non-adjustable concepts always
    /// return their catalog tier — this is the single source of truth every
    /// routing path must use instead of `DeviceAlertSeverity(level: entry.interruptionLevel)`.
    func tier(for entry: Alert.CatalogEntry) -> DeviceAlertSeverity? {
        if let adjustable = AdjustableAlert(concept: entry.concept),
           let override = tierOverrides[adjustable.rawValue]
        {
            return override
        }
        return DeviceAlertSeverity(level: entry.interruptionLevel)
    }

    /// Setting the catalog default clears the override (keeps storage minimal).
    func setTier(_ tier: DeviceAlertSeverity, for alert: AdjustableAlert) {
        if tier == defaultTier(for: alert) {
            tierOverrides.removeValue(forKey: alert.rawValue)
        } else {
            tierOverrides[alert.rawValue] = tier
        }
    }

    /// Ignores values not in `notLoopingDelayOptions`.
    func setNotLoopingDelay(minutes: Int) {
        guard Self.notLoopingDelayOptions.contains(minutes) else { return }
        notLoopingDelayMinutes = minutes
    }

    // MARK: - Lookup

    /// Find the active config for a severity at the given moment. Considers
    /// only enabled variants; picks the one whose `activeOption` matches the
    /// current day/night window, falling back to the `.always` baseline.
    /// Returns nil if every variant in this severity is disabled — caller
    /// should drop the alarm in that case (user explicitly opted out).
    func config(
        for severity: DeviceAlertSeverity,
        at _: Date,
        isNight: Bool
    ) -> DeviceAlertSeverityConfig? {
        // Critical configs are always considered enabled — the editor hides
        // the Enabled toggle on this tier, but legacy stored data may still
        // carry `isEnabled = false` from a prior install. Honoring that
        // flag here would silence the alarm despite the UI no longer
        // exposing a way to re-enable it.
        let matching = configs.filter { config in
            guard config.severity == severity else { return false }
            return severity == .critical || config.isEnabled
        }
        let windowMatch = matching.first { config in
            switch config.activeOption {
            case .always: return false // .always is the fallback, prefer specific match
            case .day: return !isNight
            case .night: return isNight
            }
        }
        if let windowMatch { return windowMatch }
        return matching.first { $0.activeOption == .always } ?? matching.first
    }

    /// All configs in a single severity tier, sorted by `activeOption`
    /// (Day & Night, Day only, Night only).
    func configs(in severity: DeviceAlertSeverity) -> [DeviceAlertSeverityConfig] {
        configs.filter { $0.severity == severity }
    }

    // MARK: - Mutators

    func add(_ config: DeviceAlertSeverityConfig) {
        configs.append(config)
        configs = Self.sorted(configs)
    }

    func update(_ config: DeviceAlertSeverityConfig) {
        guard let index = configs.firstIndex(where: { $0.id == config.id }) else { return }
        configs[index] = config
        configs = Self.sorted(configs)
    }

    func remove(_ config: DeviceAlertSeverityConfig) {
        guard canDelete(config) else { return }
        configs.removeAll { $0.id == config.id }
    }

    /// At least one `.always` config per severity must remain so every alarm
    /// has a baseline to fall back to. Other variants (.day / .night) can be
    /// freely removed.
    func canDelete(_ config: DeviceAlertSeverityConfig) -> Bool {
        guard config.activeOption == .always else { return true }
        let alwaysCount = configs.filter { $0.severity == config.severity && $0.activeOption == .always }.count
        return alwaysCount > 1
    }

    // MARK: - Sorting + Codable helpers

    private static func sorted(_ list: [DeviceAlertSeverityConfig]) -> [DeviceAlertSeverityConfig] {
        list.sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return severityRank(lhs.severity) < severityRank(rhs.severity)
            }
            return activeRank(lhs.activeOption) < activeRank(rhs.activeOption)
        }
    }

    private static func severityRank(_ severity: DeviceAlertSeverity) -> Int {
        switch severity {
        case .critical: return 0
        case .timeSensitive: return 1
        case .normal: return 2
        }
    }

    private static func activeRank(_ option: ActiveOption) -> Int {
        switch option {
        case .always: return 0
        case .day: return 1
        case .night: return 2
        }
    }

    private static func decode<T: Decodable>(
        _: T.Type,
        from defaults: UserDefaults,
        key: String
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, to key: String) {
        guard !key.isEmpty, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
