import LoopKit
import SwiftUI

struct DeviceAlarmEditorView: View {
    @ObservedObject var store: DeviceAlertsStore
    let configID: UUID
    let isNew: Bool
    var onDone: () -> Void
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState
    @State private var working: DeviceAlertSeverityConfig

    init(
        store: DeviceAlertsStore,
        initial: DeviceAlertSeverityConfig,
        isNew: Bool,
        onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.store = store
        configID = initial.id
        self.isNew = isNew
        self.onDone = onDone
        self.onCancel = onCancel
        _working = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(
                    header: Text("Behavior"),
                    footer: Text(working.severity.blurb)
                ) {
                    HStack {
                        Text(working.severity.displayName).font(.headline)
                        Spacer()
                        Text(activeLabel)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    // Critical-tier configs are always armed — the user can
                    // mute the sound via the Audio section but not turn the
                    // alarm itself off. Other tiers expose the toggle.
                    if working.severity != .critical {
                        Toggle(String(localized: "Enabled"), isOn: $working.isEnabled)
                    }
                    Toggle(
                        String(localized: "Override Silence & Focus Mode"),
                        isOn: $working.overridesSilenceAndDND
                    )
                }.listRowBackground(Color.chart)

                AlarmActiveSection(activeOption: $working.activeOption)
                AlarmAudioSection(
                    playsSound: $working.playsSound,
                    soundFilename: $working.soundFilename
                )

                Section(
                    header: Text("Applies To"),
                    footer: Text(
                        "Tap an unlocked alert to move it to another tier. Pump and sensor alarms keep their built-in tier."
                    )
                ) {
                    ForEach(conceptsForTier(working.severity), id: \.self) { concept in
                        if let adjustable = AdjustableAlert(concept: concept) {
                            NavigationLink {
                                AdjustableAlertDetailView(store: store, alert: adjustable)
                            } label: {
                                Text(concept.displayTitle)
                                    .foregroundColor(.primary)
                            }
                        } else {
                            HStack {
                                Text(concept.displayTitle)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Image(systemName: "lock.fill")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .accessibilityLabel(Text("Locked"))
                            }
                        }
                    }
                }.listRowBackground(Color.chart)

                if !isNew, store.canDelete(working) {
                    Section {
                        Button(role: .destructive) {
                            store.remove(working)
                            dismiss()
                        } label: {
                            Text("Delete Variant")
                        }
                    }.listRowBackground(Color.chart)
                }
            }
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(working.severity.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? String(localized: "Add") : String(localized: "Done")) {
                        if isNew {
                            store.add(working)
                        } else {
                            store.update(working)
                        }
                        onDone()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
    }

    private var activeLabel: String {
        switch working.activeOption {
        case .always: return String(localized: "Day & Night")
        case .day: return String(localized: "Day only")
        case .night: return String(localized: "Night only")
        }
    }

    /// Distinct alarm concepts whose *effective* tier (catalog default, or the
    /// user's override for an adjustable alert) matches this tier. Sorted by
    /// display title so the list is stable across plugin changes.
    private func conceptsForTier(_ tier: DeviceAlertSeverity) -> [LoopKit.Alert.CatalogConcept] {
        var seen: Set<LoopKit.Alert.CatalogConcept> = []
        var ordered: [LoopKit.Alert.CatalogConcept] = []
        for entry in AlertCatalogRegistry.entries
            where store.tier(for: entry) == tier
        {
            if seen.insert(entry.concept).inserted {
                ordered.append(entry.concept)
            }
        }
        return ordered.sorted { $0.displayTitle < $1.displayTitle }
    }
}

/// Detail screen for a single `AdjustableAlert` — lets the user move it to a
/// different tier (and, for Not Looping, tune the alarm delay). Writes go
/// straight to the store and are independent of the parent editor's
/// Done/Cancel, since this alert may not even live in the tier being edited
/// after the change.
struct AdjustableAlertDetailView: View {
    @ObservedObject var store: DeviceAlertsStore
    let alert: AdjustableAlert

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section(
                header: Text("Tier"),
                footer: Text(defaultTierFooter)
            ) {
                Picker(
                    String(localized: "Tier"),
                    selection: Binding(
                        get: { store.tier(for: alert) },
                        set: { store.setTier($0, for: alert) }
                    )
                ) {
                    ForEach(DeviceAlertSeverity.allCases) { severity in
                        Text(severity.displayName).tag(severity)
                    }
                }
            }.listRowBackground(Color.chart)

            if alert == .notLooping {
                Section(
                    header: Text("Alert After"),
                    footer: Text("Changes take effect after Trio's next successful loop.")
                ) {
                    Picker(
                        String(localized: "Alert After"),
                        selection: Binding(
                            get: { store.notLoopingDelayMinutes },
                            set: { store.setNotLoopingDelay(minutes: $0) }
                        )
                    ) {
                        ForEach(DeviceAlertsStore.notLoopingDelayOptions, id: \.self) { minutes in
                            Text(minutesLabel(minutes)).tag(minutes)
                        }
                    }
                }.listRowBackground(Color.chart)

                if store.tier(for: .notLooping) != .critical ||
                    store.notLoopingDelayMinutes > DeviceAlertsStore.defaultNotLoopingDelayMinutes
                {
                    Section {
                        Label {
                            Text(
                                "If this tier is snoozed, disabled, or silenced, you may not be told that Trio has stopped looping."
                            )
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                    }.listRowBackground(Color.chart)
                }
            }
        }
        .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(alert.concept.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var defaultTierFooter: String {
        String(
            format: String(
                localized: "Default: %@. This alert uses the chosen tier's sound, Focus override, day/night window and snooze."
            ),
            store.defaultTier(for: alert).displayName
        )
    }

    private func minutesLabel(_ minutes: Int) -> String {
        String(format: String(localized: "%d min"), minutes)
    }
}
