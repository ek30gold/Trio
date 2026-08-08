import CoreData
import SwiftUI

/// The Modern home layout.
///
/// A card-based restyle of the Main tab, selectable via
/// Settings → Features → User Interface → Home Screen Design. Every readout, tap target, gesture and
/// piece of state here is the same as the Classic layout's — this file changes presentation only.
extension Home.RootView {
    // MARK: - Layout constants

    /// Horizontal inset for the cards. The chart card deliberately uses a much smaller inset (see
    /// `modernChartCard`) because `MainChartView` sizes its pinned Y-axis off the full screen width.
    private var modernCardInset: CGFloat { 12 }

    /// Whether the layout is running on one of the shortest supported screens (4.7" iPhone SE and
    /// below).
    ///
    /// The Modern layout stacks strictly more chrome than Classic — three padded cards where Classic
    /// has a bobble and a single text row — so on a short screen each card has to give up a few points
    /// of padding for the chart to keep Classic's height. Uses the same screen-height threshold as
    /// `UIDevice.adjustPadding`, which handles the padding values themselves.
    private var modernIsCompactHeight: Bool {
        UIScreen.screenHeight <= UIDevice.DeviceSize.smallDevice.rawValue
    }

    // MARK: - Root

    @ViewBuilder func modernViewElements(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            if let apsManager = state.apsManager, let bluetoothManager = apsManager.bluetoothManager,
               bluetoothManager.bluetoothAuthorization != .authorized
            {
                BluetoothRequiredView()
                    .padding(.top, 10)
            } else {
                modernGlucoseCard(geo)
                    .padding(.horizontal, modernCardInset)
                    .padding(.top, UIDevice.adjustPadding(min: 6, max: 10))

                modernDeviceChipsRow
                    .padding(.horizontal, modernCardInset)
                    .padding(.top, UIDevice.adjustPadding(min: 3, max: 6))
            }

            modernStatChipsRow
                .padding(.horizontal, modernCardInset)
                .padding(.top, UIDevice.adjustPadding(min: 3, max: 6))

            modernChartCard(geo)
                .padding(.horizontal, 4)
                .padding(.top, UIDevice.adjustPadding(min: 3, max: 6))

            modernControlsRow
                .padding(.horizontal, modernCardInset)
                .padding(.vertical, UIDevice.adjustPadding(min: 2, max: 6))

            if let progress = state.bolusProgress {
                bolusView(geo: geo, progress)
                    // `min: 0` rather than `min: nil`: `adjustPadding` returns its `min` verbatim on
                    // short screens, and `padding(_:_:)` reads a nil length as the *system default*
                    // (~16pt), not as zero — so `min: nil` would silently add padding on exactly the
                    // device where the vertical budget is tightest.
                    .padding(.bottom, UIDevice.adjustPadding(min: 0, max: 20))
            } else {
                modernAdjustmentCard(geo)
                    .padding(.horizontal, modernCardInset)
                    .padding(.bottom, UIDevice.adjustPadding(min: 0, max: 20))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if notificationsDisabled {
                alertSafetyNotificationsView(geo: geo)
            }
            if let badgeImage = state.pumpStatusBadgeImage, let badgeColor = state.pumpStatusBadgeColor {
                pumpTimezoneView(badgeImage, badgeColor)
                    .padding(.horizontal, 20)
            }
        }
        .background(appState.trioBackgroundColor(for: colorScheme))
        .onReceive(
            resolver.resolve(AlertPermissionsChecker.self)!.$notificationsDisabled,
            perform: {
                if notificationsDisabled != $0 {
                    notificationsDisabled = $0
                    if notificationsDisabled {
                        debug(.default, "notificationsDisabled")
                    }
                }
            }
        )
    }

    // MARK: - Glucose card

    /// Colour of the current reading.
    ///
    /// Uses the same `Trio.getDynamicGlucoseColor` call as `CurrentGlucoseView`, including its
    /// hardcoded 55/220 substitution under the dynamic colour scheme. It differs from Classic in one
    /// respect: Classic leaves in-range readings `.primary` and only colours out-of-range ones,
    /// whereas Modern colours every reading so the number always agrees with the range rail beneath it.
    private var modernGlucoseColor: Color {
        guard let glucoseValue = state.latestTwoGlucoseValues.last?.glucose else { return .secondary }

        let value = Decimal(glucoseValue)
        let hardCodedLow = Decimal(55)
        let hardCodedHigh = Decimal(220)
        let isDynamicColorScheme = state.glucoseColorScheme == .dynamicColor

        return Trio.getDynamicGlucoseColor(
            glucoseValue: value,
            highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : state.highGlucose,
            lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : state.lowGlucose,
            targetGlucose: state.currentGlucoseTarget,
            glucoseColorScheme: state.glucoseColorScheme
        )
    }

    /// Signed delta between the last two readings. Mirrors `CurrentGlucoseView.delta`, minus that
    /// view's leading whitespace padding, which the chip's own padding replaces here.
    private var modernDeltaString: String {
        let glucose = state.latestTwoGlucoseValues
        guard glucose.count >= 2 else { return "--" }

        var lastGlucose = Decimal(glucose.last?.glucose ?? 0)
        var secondLastGlucose = Decimal(glucose.first?.glucose ?? 0)
        if state.units == .mmolL {
            lastGlucose = lastGlucose.asMmolL
            secondLastGlucose = secondLastGlucose.asMmolL
        }

        let delta = lastGlucose - secondLastGlucose

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if state.units == .mmolL {
            formatter.maximumFractionDigits = 1
            formatter.minimumFractionDigits = 1
            formatter.roundingMode = .halfUp
        } else {
            formatter.maximumFractionDigits = 0
        }
        formatter.positivePrefix = "+"
        formatter.negativePrefix = "-"

        return formatter.string(from: delta as NSNumber) ?? "--"
    }

    @ViewBuilder func modernGlucoseCard(_ geo: GeometryProxy) -> some View {
        // Scales with available height so the card does not crowd out the chart on smaller devices.
        // The 44pt ceiling keeps this card's three stacked rows within roughly the same vertical
        // budget as Classic's 130pt glucose bobble, so the chart below can keep Classic's height.
        // It is still comfortably larger than the 40pt `CurrentGlucoseView` uses.
        let glucoseFontSize = min(max(geo.size.height * 0.07, 34), 44)
        let glucoseColor = modernGlucoseColor
        let cardSpacing: CGFloat = modernIsCompactHeight ? 6 : 8

        ModernCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: cardSpacing) {
                if state.cgmAvailable {
                    HStack(alignment: .top) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let glucoseValue = state.latestTwoGlucoseValues.last?.glucose {
                                let displayGlucose = state.units == .mgdL
                                    ? Decimal(glucoseValue).description
                                    : Decimal(glucoseValue).formattedAsMmolL

                                Text(glucoseValue == 400 ? "HIGH" : displayGlucose)
                                    .font(.system(size: glucoseFontSize, weight: .bold, design: .rounded))
                                    .foregroundStyle(glucoseColor)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)

                                Image(systemName: "arrow.right")
                                    .font(.system(size: glucoseFontSize * 0.42, weight: .bold))
                                    .foregroundStyle(glucoseColor)
                                    .rotationEffect(
                                        .degrees(
                                            state.latestTwoGlucoseValues.last?.directionEnum?
                                                .modernTrendRotation ?? 0
                                        )
                                    )
                                    .animation(.default, value: state.latestTwoGlucoseValues.last?.directionEnum)
                            } else {
                                Text("--")
                                    .font(.system(size: glucoseFontSize, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            Text(modernDeltaString + " " + state.units.rawValue)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .fontDesign(.rounded)
                                .foregroundStyle(glucoseColor)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 9)
                                .background(
                                    Capsule().fill(glucoseColor.opacity(0.12))
                                )

                            Text(TimeAgoFormatter.minutesAgo(from: state.latestTwoGlucoseValues.last?.date))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GlucoseRangeRail(
                        glucoseValue: state.latestTwoGlucoseValues.last.map { Decimal($0.glucose) },
                        units: state.units,
                        lowGlucose: state.lowGlucose,
                        highGlucose: state.highGlucose,
                        currentGlucoseTarget: state.currentGlucoseTarget,
                        glucoseColorScheme: state.glucoseColorScheme
                    )
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "sensor.tag.radiowaves.forward.fill")
                            .font(.body)
                            .imageScale(.large)
                        Text("Add CGM").font(.caption).bold()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                modernStatusPills
            }
            .padding(.horizontal, 16)
            .padding(.top, modernIsCompactHeight ? 10 : 12)
            .padding(.bottom, modernIsCompactHeight ? 8 : 10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !state.cgmAvailable {
                showCGMSelection.toggle()
            } else {
                state.shouldDisplayCGMSetupSheet.toggle()
            }
        }
        .onLongPressGesture {
            let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
            impactHeavy.impactOccurred()
            state.showModal(for: .snooze)
        }
    }

    /// Loop status and eventual BG. `LoopView` is embedded directly rather than reimplemented, so its
    /// colour thresholds, "looping" spinner and manual/open-loop states all carry over unchanged.
    @ViewBuilder private var modernStatusPills: some View {
        HStack(spacing: 8) {
            LoopView(
                closedLoop: state.closedLoop,
                timerDate: state.timerDate,
                isLooping: state.isLooping,
                lastLoopDate: state.lastLoopDate,
                manualTempBasal: state.manualTempBasal,
                determination: state.determinationsFromPersistence
            )
            .onTapGesture {
                state.isLoopStatusPresented = true
            }
            .onLongPressGesture {
                let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                impactHeavy.impactOccurred()
                state.runLoop()
            }

            // `LoopView` draws its capsule from `.callout` text plus 5/10 padding and a 2pt stroke.
            // This pill repeats that recipe exactly — same font, padding and stroke — so the two
            // capsules resolve to the same height instead of the eventual-BG one sitting short, and
            // they keep matching as Dynamic Type scales both fonts together.
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: "arrow.right.circle")
                    .font(.callout)
                    .fontWeight(.bold)

                if let eventualBG = state.enactedAndNonEnactedDeterminations.first?.eventualBG {
                    let eventualGlucose = eventualBG as Decimal
                    Text(state.units == .mgdL ? eventualGlucose.description : eventualGlucose.formattedAsMmolL)
                        .font(.callout)
                        .fontWeight(.bold)
                        .fontDesign(.rounded)
                } else {
                    Text("--")
                        .font(.callout)
                        .fontWeight(.bold)
                        .fontDesign(.rounded)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .overlay(
                Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 2)
            )

            Spacer()
        }
    }

    // MARK: - Device chips

    @ViewBuilder var modernDeviceChipsRow: some View {
        if let pumpStatusHighlightMessage = state.pumpStatusHighlightMessage {
            ModernCard(cornerRadius: 15) {
                Text(pumpStatusHighlightMessage)
                    .font(.footnote)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
            .onTapGesture { modernPumpTapAction() }
        } else if state.reservoir == nil, state.batteryFromPersistence.isEmpty {
            ModernCard(cornerRadius: 15) {
                HStack(spacing: 6) {
                    Image(systemName: "keyboard.onehanded.left")
                        .font(.caption)
                    Text("Add pump")
                        .font(.caption)
                        .bold()
                }
                .frame(maxWidth: .infinity)
                // Matches `ModernChip`'s default height so the empty state is the same size as the
                // populated row it replaces.
                .frame(height: 28)
            }
            .contentShape(Rectangle())
            .onTapGesture { modernPumpTapAction() }
        } else {
            HStack(spacing: 7) {
                if let reservoir = state.reservoir {
                    ModernChip(
                        systemImage: "cross.vial.fill",
                        value: reservoir == 0xDEAD_BEEF
                            ? "50+ " + String(localized: "U", comment: "Insulin unit")
                            : (Formatter.integerFormatter.string(from: reservoir as NSNumber) ?? "0")
                            + String(localized: " U", comment: "Insulin unit"),
                        tint: PumpDisplayFormatting.reservoirColor(for: reservoir)
                    )
                }

                if let shouldBatteryDisplay = state.batteryFromPersistence.first?.display, shouldBatteryDisplay {
                    ModernChip(
                        systemImage: "battery.100",
                        value: "\(Formatter.integerFormatter.string(for: state.batteryFromPersistence.first?.percent ?? 100) ?? "100") %",
                        tint: PumpDisplayFormatting.batteryColor(percent: state.batteryFromPersistence.first?.percent)
                    )
                }

                if let expiresAt = state.pumpExpiresAtDate {
                    ModernChip(
                        systemImage: PumpDisplayFormatting.hourglassIcon(
                            expiresAtDate: expiresAt,
                            activatedAtDate: state.pumpActivatedAtDate,
                            timerDate: state.timerDate
                        ),
                        value: PumpDisplayFormatting.remainingTimeString(
                            time: expiresAt.timeIntervalSince(state.timerDate)
                        ),
                        tint: PumpDisplayFormatting.timerColor(
                            expiresAtDate: expiresAt,
                            activatedAtDate: state.pumpActivatedAtDate,
                            timerDate: state.timerDate
                        )
                    )
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { modernPumpTapAction() }
        }
    }

    private func modernPumpTapAction() {
        if state.pumpDisplayState == nil {
            // shows user confirmation dialog with pump model choices, then proceeds to setup
            showPumpSelection.toggle()
        } else {
            // sends user to pump settings
            state.shouldDisplayPumpSetupSheet.toggle()
        }
    }

    // MARK: - Stat chips

    @ViewBuilder var modernStatChipsRow: some View {
        HStack(spacing: 7) {
            ModernStatChip(label: String(localized: "IOB"), tint: .secondary) {
                Text(
                    (
                        Formatter.decimalFormatterWithTwoFractionDigits
                            .string(from: state.currentIOB as NSNumber) ?? "0"
                    ) + String(localized: " U", comment: "Insulin unit")
                )
                .foregroundStyle(Color.insulin)
            }

            ModernStatChip(label: String(localized: "COB"), tint: .secondary) {
                Text(
                    (
                        Formatter.decimalFormatterWithTwoFractionDigits.string(
                            from: NSNumber(value: state.enactedAndNonEnactedDeterminations.first?.cob ?? 0)
                        ) ?? "0"
                    ) + String(localized: " g", comment: "gram of carbs")
                )
                .foregroundStyle(Color.loopYellow)
            }

            // All three chips are laid out at equal layout priority, so the `maxWidth: .infinity`
            // inside `ModernStatChip` makes the HStack split the row into equal thirds.
            //
            // The basal readout is the longest of the three, but it does NOT get a layout priority
            // bump: in an HStack the highest-priority child is offered all the remaining width
            // first, and a child declaring `maxWidth: .infinity` accepts every point of it, which
            // starved the IOB and COB chips down to their (near-zero, ellipsis-only) minimum width.
            // The mockup's fixed 1.25x is not reproduced literally either — a hard ratio clips
            // under larger Dynamic Type sizes. A third of the row fits "3.15 U/hr" at default type
            // with room to spare, and the chip's own `lineLimit(1)` + `minimumScaleFactor` handle
            // the rarer long forms (e.g. the manual-basal suffix) by scaling rather than clipping.
            modernBasalChip
        }
    }

    @ViewBuilder private var modernBasalChip: some View {
        if state.maxIOB == 0.0 {
            ModernStatChip(label: String(localized: "Max IOB"), tint: Color.loopRed) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text("0 U")
                }
                .foregroundStyle(Color.loopRed)
            }
        } else {
            // Only display the insulin delivery rate info if the pump is not
            // suspended and is available (e.g., pod is paired & not faulted).
            let pumpAvailable = state.apsManager.isScheduledBasal != nil
            let isScheduled = state.apsManager?.isScheduledBasal == true

            ModernStatChip(label: String(localized: "Basal"), tint: .secondary) {
                if !state.apsManager.isSuspended, pumpAvailable {
                    if let basalString = self.basalString {
                        Text(basalString)
                            .foregroundStyle(Color.insulinTintColor)
                            // Matches the Classic layout, which dims a merely-scheduled rate.
                            .opacity(isScheduled ? 0.6 : 1.0)
                    } else {
                        Text("No Data")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("--")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Chart card

    /// The chart card.
    ///
    /// `MainChartView` sizes its three stacked regions (0.05 basal + 0.28 main + 0.12 IOB/COB, ~0.45
    /// in total) as fractions of the `GeometryProxy` it is handed. It is deliberately handed the
    /// *content* proxy — the same one `classicViewElements` passes to `mainChart(geo:)` — rather than
    /// a proxy for this card, so the charts come out at exactly Classic's height instead of being
    /// scaled down to whatever the surrounding cards happen to leave over. The card then sizes itself
    /// to the chart rather than the other way round; every other element in the Modern layout is
    /// budgeted against the remaining ~0.55 of the content height.
    @ViewBuilder func modernChartCard(_ geo: GeometryProxy) -> some View {
        ModernCard(cornerRadius: 20) {
            MainChartView(
                geo: geo,
                // Same subtraction Classic makes: the notifications banner is added as a safe-area
                // inset on this layout's root `VStack`, so it takes its height out of the space the
                // stack has to lay out in, and the chart has to give the same amount back.
                safeAreaSize: notificationsDisabled == true ? safeAreaSize : 0,
                units: state.units,
                hours: state.filteredHours,
                highGlucose: state.highGlucose,
                lowGlucose: state.lowGlucose,
                currentGlucoseTarget: state.currentGlucoseTarget,
                glucoseColorScheme: state.glucoseColorScheme,
                screenHours: state.hours,
                displayXgridLines: state.displayXgridLines,
                displayYgridLines: state.displayYgridLines,
                thresholdLines: state.thresholdLines,
                state: state
            )
            .padding(.vertical, UIDevice.adjustPadding(min: 2, max: 6))
        }
        // The chart's own minimum heights set the floor; this lets the card additionally soak up any
        // space the elements above and below do not use on a taller device, which `MainChartView`'s
        // internal `Spacer()` passes on to the gap above the IOB/COB band.
        .frame(maxHeight: .infinity)
    }

    // MARK: - Controls row

    @ViewBuilder var modernControlsRow: some View {
        let buttonColor = (colorScheme == .dark ? Color.white : Color.black).opacity(0.8)

        HStack {
            modernChipButton(
                label: String(localized: "Stats", comment: "Stats icon in main view"),
                iconString: statsIconString,
                color: buttonColor,
                action: { state.showModal(for: .statistics) }
            )

            Spacer()

            HStack(spacing: 4) {
                ForEach(timeButtons) { button in
                    Button(action: {
                        state.hours = button.hours
                    }) {
                        Group {
                            if button.active {
                                Text(
                                    button.hours.description + "\u{00A0}" +
                                        String(localized: "h", comment: "h")
                                )
                            } else {
                                Text(button.hours.description)
                            }
                        }
                        .font(.footnote)
                        .fontWeight(button.active ? .semibold : .regular)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .foregroundColor(button.active ? Color.white : buttonColor)
                        .background(button.active ? Color.tabBar : Color.clear)
                        .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            modernChipButton(
                label: String(localized: "Info", comment: "Info icon in main view"),
                iconString: "info",
                color: buttonColor,
                action: { state.isLegendPresented.toggle() }
            )
        }
    }

    @ViewBuilder private func modernChipButton(
        label: String,
        iconString: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: iconString)
                Text(label)
            }
            .font(.footnote)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .foregroundStyle(color)
            .background(
                Capsule().fill(Color.chart)
            )
        }
    }

    // MARK: - Adjustment card

    /// Same content and behaviour as `adjustmentView(geo:)` — the branch structure, the shared
    /// override / temp-target / cancel sub-views and all three confirmation dialogs are reused
    /// verbatim. Only the card container is restyled.
    @ViewBuilder func modernAdjustmentCard(_ geo: GeometryProxy) -> some View {
        ModernCard(cornerRadius: 16) {
            HStack {
                if let overrideString = overrideString, let tempTargetString = tempTargetString {
                    HStack {
                        adjustmentsOverrideView(overrideString)

                        Spacer()

                        Divider()
                            .frame(height: geo.size.height * 0.05)
                            .padding(.horizontal, 2)

                        adjustmentsTempTargetView(tempTargetString)

                        Spacer()

                        adjustmentsCancelView({
                            if !latestTempTarget.isEmpty, !latestOverride.isEmpty {
                                showCancelConfirmDialog = true
                            } else if !latestOverride.isEmpty {
                                showCancelAlert = true
                            } else if !latestTempTarget.isEmpty {
                                showCancelAlert = true
                            }
                        })
                    }
                } else if let overrideString = overrideString {
                    adjustmentsOverrideView(overrideString)
                    Spacer()
                    adjustmentsCancelOverrideView()

                } else if let tempTargetString = tempTargetString {
                    HStack {
                        adjustmentsTempTargetView(tempTargetString)
                        Spacer()
                        adjustmentsCancelTempTargetView()
                    }
                } else {
                    noActiveAdjustmentsView()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: max(geo.size.height * 0.068, 42))
            .confirmationDialog("Adjustment to Stop", isPresented: $showCancelConfirmDialog) {
                Button("Stop Override", role: .destructive) {
                    Task {
                        guard let objectID = latestOverride.first?.objectID else { return }
                        await state.cancelOverride(withID: objectID)
                    }
                }
                Button("Stop Temp Target", role: .destructive) {
                    Task {
                        guard let objectID = latestTempTarget.first?.objectID else { return }
                        await state.cancelTempTarget(withID: objectID)
                    }
                }
                Button("Stop All Adjustments", role: .destructive) {
                    Task {
                        guard let overrideObjectID = latestOverride.first?.objectID else { return }
                        await state.cancelOverride(withID: overrideObjectID)

                        guard let tempTargetObjectID = latestTempTarget.first?.objectID else { return }
                        await state.cancelTempTarget(withID: tempTargetObjectID)
                    }
                }
            } message: {
                Text("Select Adjustment")
            }
        }
    }
}
