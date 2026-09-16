import CoreData
import SwiftUI

extension Adjustments.RootView {
    @ViewBuilder func overrides() -> some View {
        if state.isOverrideEnabled, state.activeOverrideName.isNotEmpty {
            currentActiveAdjustment
        }
        if !state.scheduledOverrides.isEmpty {
            scheduledOverrideBanner
            scheduledOverridesSection
        }
        if state.overridePresets.isNotEmpty {
            overridePresets
        } else {
            defaultText
        }
    }

    /// One banner per scheduled Override, so a conflicting second one (blocked at scheduling time)
    /// can never hide the first.
    private var scheduledOverrideBanner: some View {
        ForEach(state.scheduledOverrides) { override in
            Section {
                HStack {
                    Text(
                        "\(override.name ?? String(localized: "Override")) " +
                            String(localized: "is scheduled for") +
                            " \(formattedScheduledTime(for: override.date))"
                    )
                    .foregroundStyle(.white)
                    Spacer()
                    Button {
                        Task {
                            await state.cancelScheduledOverride(override.objectID)
                        }
                    } label: {
                        Text(String(localized: "Cancel Future Override"))
                            .foregroundStyle(.white)
                            .bold()
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedOverride = override
                    state.showOverrideEditSheet = true
                }
            }
            .listRowBackground(Color.purple.opacity(0.8))
        }
    }

    private var scheduledOverridesSection: some View {
        Section {
            ForEach(state.scheduledOverrides) { override in
                HStack {
                    Text(override.name ?? String(localized: "Scheduled Override"))
                    Spacer()
                    Text("Starts in \(formattedTimeRemaining((override.date ?? Date()).timeIntervalSinceNow))")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedOverride = override
                    state.showOverrideEditSheet = true
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await state.cancelScheduledOverride(override.objectID) }
                    } label: {
                        Label(String(localized: "Cancel"), systemImage: "xmark.circle.fill")
                    }
                }
            }
            .listRowBackground(Color.chart)
        } header: {
            Text("Scheduled Overrides")
        }
    }

    private func formattedScheduledTime(for date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    var overridePresets: some View {
        Section {
            ForEach(state.overridePresets) { preset in
                overridesView(for: preset, showCheckMark: showOverrideCheckmark) {
                    requestOverridePresetActivation(preset)
                }
                .contextMenu {
                    actionButtonsForOverrides(for: preset)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    actionButtonsForOverrides(for: preset, deleteRole: nil)
                }
            }
            .onMove(perform: state.reorderOverride)
            .listRowBackground(Color.chart)
        } header: {
            Text("Override Presets")
        } footer: {
            HStack {
                Image(systemName: "hand.draw.fill").foregroundStyle(.primary)
                Text("Swipe left to edit or delete an override preset. Hold, drag and drop to reorder a preset.")
            }
        }
    }

    func overrideDeleteConfirmation(_ content: some View) -> some View {
        let target = overrideToDelete
        let isRunning = target != nil && state.currentActiveOverride == target

        return content.glassActionSheet(
            "Delete the Override Preset \"\(target?.name ?? "")\"?",
            message: isRunning ? Text("This override preset is currently running. Deleting will stop it.") : nil,
            isPresented: Binding(
                get: { overrideToDelete != nil },
                set: { if !$0 { overrideToDelete = nil } }
            ),
            actions: [
                GlassSheetAction(
                    isRunning ? "Stop and Delete" : "Delete",
                    role: .destructive
                ) {
                    guard let target else { return }
                    if isRunning {
                        Task {
                            await state.disableAllActiveOverrides(createOverrideRunEntry: true)
                        }
                    }
                    Task {
                        await state.invokeOverridePresetDeletion(target.objectID)
                    }
                }
            ]
        )
    }

    private func requestOverridePresetActivation(_ preset: OverrideStored) {
        let activation = PendingPresetActivation.override(
            objectID: preset.objectID,
            presetID: preset.id,
            name: preset.name ?? ""
        )

        requestPresetActivation(activation)
    }

    func actionButtonsForOverrides(
        for preset: OverrideStored,
        deleteRole: ButtonRole? = .destructive
    ) -> some View {
        Group {
            Button(role: deleteRole) {
                overrideToDelete = preset
            } label: {
                Label("Delete", systemImage: "trash.fill")
            }
            .tint(.red)
            Button {
                // Set the selected Override to the chosen Preset and pass it to the Edit Sheet
                selectedOverride = preset
                state.showOverrideEditSheet = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
            Button {
                selectedOverride = preset
                state.showOverrideEditSheet = true
            } label: {
                Label(String(localized: "Schedule"), systemImage: "clock")
            }
        }
    }

    var overrideLabelDivider: some View {
        Divider()
            .frame(width: 1, height: 20)
    }

    var stickyStopOverrideButton: some View {
        ZStack {
            Rectangle()
                .frame(width: UIScreen.main.bounds.width, height: 65)
                .foregroundStyle(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color.white)
                .background(.thinMaterial)
                .opacity(0.8)
                .clipShape(Rectangle())

            Button(action: {
                showCancelOverrideConfirmDialog = true
            }, label: {
                Text("Stop Override")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
            })
                .frame(width: UIScreen.main.bounds.width * 0.9, height: 40, alignment: .center)
                .disabled(!state.isOverrideEnabled)
                .background(!state.isOverrideEnabled ? Color(.systemGray4) : Color(.systemRed))
                .tint(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                .padding(5)
        }
    }

    @ViewBuilder func overridesView(
        for preset: OverrideStored,
        showCheckMark _: Bool = false,
        onTap: (() -> Void)? = nil
    ) -> some View {
        let isSelected = preset.id == selectedOverridePresetID
        let name = preset.name ?? ""
        let indefinite = preset.indefinite
        let duration = preset.duration?.decimalValue ?? Decimal(0)
        let percentage = preset.percentage
        let smbMinutes = preset.smbMinutes?.decimalValue ?? Decimal(0)
        let uamMinutes = preset.uamMinutes?.decimalValue ?? Decimal(0)

        let target: String = {
            guard let targetValue = preset.target, targetValue != 0 else { return "" }
            return state.units == .mgdL ? targetValue.description : targetValue.decimalValue.formattedAsMmolL
        }()

        let targetString = target.isEmpty ? "" : "\(target) \(state.units.rawValue)"

        let durationString = indefinite ? "" : "\(state.formatHoursAndMinutes(Int(duration)))"

        let scheduledSMBString: String = {
            guard preset.smbIsScheduledOff, preset.start != preset.end else { return "" }
            return " \(formatTimeRange(start: preset.start?.stringValue, end: preset.end?.stringValue))"
        }()

        let smbString: String = {
            guard preset.smbIsOff || preset.smbIsScheduledOff else { return "" }
            return "SMBs Off\(scheduledSMBString)"
        }()

        let maxSmbMinsString: String = {
            guard smbMinutes != 0, preset.advancedSettings, !preset.smbIsOff,
                  smbMinutes != state.defaultSmbMinutes else { return "" }
            return "\(smbMinutes.formatted()) min SMB"
        }()

        let maxUamMinsString: String = {
            guard uamMinutes != 0, preset.advancedSettings, !preset.smbIsOff,
                  uamMinutes != state.defaultUamMinutes else { return "" }
            return "\(uamMinutes.formatted()) min UAM"
        }()

        let isfAndCrString: String = {
            switch (preset.isfAndCr, preset.isf, preset.cr) {
            case (_, true, true),
                 (true, _, _):
                return " ISF/CR"
            case (false, true, false):
                return " ISF"
            case (false, false, true):
                return " CR"
            default:
                return ""
            }
        }()

        let percentageString = percentage != 100 ? "\(Int(percentage))%\(isfAndCrString)" : ""

        // Combine all labels into a single array, filtering out empty strings
        let labels: [String] = [
            durationString,
            percentageString,
            targetString,
            smbString,
            maxSmbMinsString,
            maxUamMinsString
        ].filter { !$0.isEmpty }

        if !name.isEmpty {
            ZStack(alignment: .trailing) {
                HStack {
                    VStack {
                        HStack {
                            Text(name)
                            Spacer()
                        }
                        HStack(spacing: 5) {
                            ForEach(labels, id: \.self) { label in
                                Text(label)
                                if label != labels.last { // Add divider between labels
                                    overrideLabelDivider
                                }
                            }
                            Spacer()
                        }
                        .padding(.top, 2)
                        .foregroundColor(.secondary)
                        .font(.caption)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTap?()
                    }
                }
                // show checkmark to indicate if the preset was actually pressed
                if showOverrideCheckmark && isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .imageScale(.large)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.green)
                } else {
                    Image(systemName: "line.3.horizontal")
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text(labels.joined(separator: ", ")))
            .accessibilityHint(Text(String(localized: "Double tap to enable this override", comment: "Accessibility hint")))
            .accessibilityAddTraits(showOverrideCheckmark && isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onTap?() }
        }
    }
}
