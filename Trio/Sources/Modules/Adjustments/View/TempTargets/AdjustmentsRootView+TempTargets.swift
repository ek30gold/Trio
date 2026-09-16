import CoreData
import SwiftUI

extension Adjustments.RootView {
    @ViewBuilder func tempTargets() -> some View {
        if state.isTempTargetEnabled, state.activeTempTargetName.isNotEmpty {
            currentActiveAdjustment(for: .tempTargets)
        }
        if state.scheduledTempTargets.isNotEmpty {
            scheduledTempTargetBanner
            scheduledTempTargets
        }
        if state.tempTargetPresets.isNotEmpty {
            tempTargetPresets
        } else {
            defaultText(for: .tempTargets)
        }
    }

    /// One banner per scheduled Temp Target, so a conflicting second one (blocked at scheduling
    /// time) can never hide the first.
    private var scheduledTempTargetBanner: some View {
        ForEach(state.scheduledTempTargets) { tempTarget in
            Section {
                HStack {
                    Text(
                        "\(tempTarget.name ?? String(localized: "Temp Target")) " +
                            String(localized: "is scheduled for") +
                            " \(formattedScheduledTempTargetTime(for: tempTarget))"
                    )
                    .foregroundStyle(.white)
                    Spacer()
                    Button {
                        Task {
                            await state.cancelScheduledTempTarget(tempTarget.objectID)
                        }
                    } label: {
                        Text(String(localized: "Cancel Future Temp Target"))
                            .foregroundStyle(.white)
                            .bold()
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedTempTarget = tempTarget
                    state.showTempTargetEditSheet = true
                }
            }
            .listRowBackground(Color.purple.opacity(0.8))
        }
    }

    private var scheduledTempTargets: some View {
        Section {
            ForEach(state.scheduledTempTargets) { tempTarget in
                tempTargetView(for: tempTarget)
                    // A single `.swipeActions` call: SwiftUI does not merge two calls for the
                    // same edge, so a second call would silently replace the first instead of
                    // adding to it.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await state.cancelScheduledTempTarget(tempTarget.objectID) }
                        } label: {
                            Label(String(localized: "Cancel"), systemImage: "xmark.circle.fill")
                        }
                        Button {
                            selectedTempTarget = tempTarget
                            state.showTempTargetEditSheet = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
            .listRowBackground(Color.chart)
        } header: {
            Text("Scheduled Temp Targets")
        }
    }

    private func formattedScheduledTempTargetTime(for tempTarget: TempTargetStored) -> String {
        guard let date = tempTarget.date else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private var tempTargetPresets: some View {
        Section {
            ForEach(state.tempTargetPresets) { preset in
                tempTargetView(for: preset, showCheckmark: showTempTargetCheckmark) {
                    requestTempTargetPresetActivation(preset)
                }
                .contextMenu {
                    actionButtonsForTempTargets(for: preset, showScheduleAction: true)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    actionButtonsForTempTargets(for: preset, deleteRole: nil, showScheduleAction: true)
                }
            }
            .onMove(perform: state.reorderTempTargets)
            .listRowBackground(Color.chart)
        } header: {
            Text("Temporary Target Presets")
        } footer: {
            HStack {
                Image(systemName: "hand.draw.fill").foregroundStyle(.primary)
                Text("Swipe left to edit or delete a temporary target preset. Hold, drag and drop to reorder a preset.")
            }
        }
    }

    private func requestTempTargetPresetActivation(_ preset: TempTargetStored) {
        let activation = PendingPresetActivation.tempTarget(
            objectID: preset.objectID,
            presetID: preset.id?.uuidString,
            name: preset.name ?? ""
        )

        requestPresetActivation(activation)
    }

    private func actionButtonsForTempTargets(
        for tempTarget: TempTargetStored,
        deleteRole: ButtonRole? = .destructive,
        showScheduleAction: Bool = false
    ) -> some View {
        Group {
            Button(role: deleteRole) {
                tempTargetToDelete = tempTarget
            } label: {
                Label("Delete", systemImage: "trash.fill")
            }
            .tint(.red)
            Button {
                selectedTempTarget = tempTarget
                state.showTempTargetEditSheet = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
            // Only offered from the Preset list — a row already in `scheduledTempTargets` is
            // itself the scheduled entry, so scheduling it again would be meaningless.
            if showScheduleAction {
                Button {
                    selectedTempTarget = tempTarget
                    state.showTempTargetEditSheet = true
                } label: {
                    Label(String(localized: "Schedule"), systemImage: "clock")
                }
            }
        }
    }

    func tempTargetDeleteConfirmation(_ content: some View) -> some View {
        let target = tempTargetToDelete
        let isRunning = target != nil && state.currentActiveTempTarget == target

        return content.glassActionSheet(
            "Delete the Temp Target Preset \"\(target?.name ?? "")\"?",
            message: isRunning ? Text("This Temp Target preset is currently running. Deleting will stop it.") : nil,
            isPresented: Binding(
                get: { tempTargetToDelete != nil },
                set: { if !$0 { tempTargetToDelete = nil } }
            ),
            actions: [
                GlassSheetAction(
                    isRunning ? "Stop and Delete" : "Delete",
                    role: .destructive
                ) {
                    guard let target else { return }
                    if isRunning {
                        Task {
                            await state.disableAllActiveTempTargets(createTempTargetRunEntry: true)
                        }
                    }
                    Task {
                        await state.invokeTempTargetPresetDeletion(target.objectID)
                    }
                }
            ]
        )
    }

    var stickyStopTempTargetButton: some View {
        ZStack {
            Rectangle()
                .frame(width: UIScreen.main.bounds.width, height: 65)
                .foregroundStyle(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color.white)
                .background(.thinMaterial)
                .opacity(0.8)
                .clipShape(Rectangle())

            Button(action: {
                showCancelTempTargetConfirmDialog = true
            }, label: {
                Text("Stop Temp Target")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
            })
                .frame(width: UIScreen.main.bounds.width * 0.9, height: 40, alignment: .center)
                .disabled(!state.isTempTargetEnabled)
                .background(!state.isTempTargetEnabled ? Color(.systemGray4) : Color(.systemRed))
                .tint(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(5)
        }
    }

    private func tempTargetView(
        for tempTarget: TempTargetStored,
        showCheckmark: Bool = false,
        onTap: (() -> Void)? = nil
    ) -> some View {
        let target = tempTarget.target ?? 100
        let tempTargetValue = Decimal(target as! Double.RawValue)
        let isSelected = tempTarget.id?.uuidString == selectedTempTargetPresetID
        let tempTargetHalfBasal = Decimal(
            tempTarget.halfBasalTarget as? Double
                .RawValue ?? Double(state.settingHalfBasalTarget)
        )
        let percentage = Int(
            TempTargetCalculations.computeAdjustedPercentage(
                halfBasalTarget: tempTargetHalfBasal,
                target: tempTargetValue,
                autosensMax: state.autosensMax
            )
        )
        let remainingTime = tempTarget.date?.timeIntervalSinceNow ?? 0

        let row = ZStack(alignment: .trailing) {
            HStack {
                VStack(alignment: .leading) {
                    HStack {
                        Text(tempTarget.name ?? "")
                        Spacer()
                        if remainingTime > 0 {
                            Text("Starts in \(formattedTimeRemaining(remainingTime))")
                                .foregroundColor(colorScheme == .dark ? .orange : .accentColor)
                        }
                    }
                    HStack(spacing: 2) {
                        Text(formattedGlucose(glucose: target as Decimal))
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text("for")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text("\(Formatter.integerFormatter.string(from: (tempTarget.duration ?? 0) as NSNumber)!)")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text("min")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        if state.isAdjustSensEnabled(usingTarget: tempTargetValue) {
                            Text(", \(percentage)%")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        Spacer()
                    }
                    .padding(.top, 2)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onTap?()
                }
            }
            if showCheckmark && isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .imageScale(.large)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.green)
            } else if onTap != nil {
                Image(systemName: "line.3.horizontal")
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(tempTarget.name ?? ""))
        .accessibilityValue(Text(
            formattedGlucose(glucose: target as Decimal) + " "
                + String(localized: "for", comment: "duration connector") + " "
                + (Formatter.integerFormatter.string(from: (tempTarget.duration ?? 0) as NSNumber) ?? "0") + " "
                + String(localized: "min", comment: "minutes abbreviation")
                + (state.isAdjustSensEnabled(usingTarget: tempTargetValue) ? ", \(percentage)%" : "")
        ))
        // Only tappable rows (presets) are buttons; scheduled rows are read-only, so they get
        // neither the button trait, an activation, nor a hint.
        return Group {
            if let onTap {
                row
                    .accessibilityHint(Text(String(localized: "Enables this temp target", comment: "Accessibility hint")))
                    .accessibilityAddTraits(showCheckmark && isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { onTap() }
            } else {
                row
                    .accessibilityAddTraits(showCheckmark && isSelected ? .isSelected : [])
            }
        }
    }
}
