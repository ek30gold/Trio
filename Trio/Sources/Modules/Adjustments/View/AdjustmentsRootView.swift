import CoreData
import SwiftUI
import Swinject

/// Disables the enclosing `UINavigationController`'s edge-swipe-to-pop gesture.
/// Adjustments is the root of its own tab-specific `NavigationStack` with no push
/// destinations, so the pop gesture has nothing to do — but left enabled, it still
/// claims rightward drags before the paging gesture below sees them, which is what
/// made swiping from Temp Targets back to Overrides fail while the reverse
/// direction worked.
///
/// This assumes Adjustments never gains a `navigationDestination`/`NavigationLink` of
/// its own — if one is ever added, its back-swipe would be silently disabled by this
/// with no compiler warning. Remove this struct and its `.background(...)` call site
/// below if that changes.
private struct DisableInteractivePopGesture: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context _: Context) {
        DispatchQueue.main.async {
            // `.navigationController` walks the full ancestor chain itself; going through
            // `.parent` first would only check one level up and could miss the navigation
            // controller if SwiftUI inserts more than one wrapper between this controller
            // and it.
            uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        }
    }
}

extension Adjustments {
    struct RootView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()
        @State var isEditing = false
        @State var showOverrideCreationSheet = false
        @State var showTempTargetCreationSheet = false
        @State var showingDetail = false
        @State var showOverrideCheckmark: Bool = false
        @State var showTempTargetCheckmark: Bool = false
        @State var selectedOverridePresetID: String?
        @State var selectedTempTargetPresetID: String?
        @State var selectedOverride: OverrideStored?
        @State var selectedTempTarget: TempTargetStored?
        @State var isConfirmOverrideDeletePresented = false
        @State var isConfirmTempTargetDeletePresented = false
        @State var isPromptPresented = false
        @State var isRemoveAlertPresented = false
        @State var removeAlert: Alert?
        @State var isEditingTT = false
        @State var showCancelOverrideConfirmDialog = false
        @State var showCancelTempTargetConfirmDialog = false
        @State var pendingPresetActivation: PendingPresetActivation?

        private var shouldDisplayStickyOverrideStopButton: Bool {
            state.isOverrideEnabled && state.activeOverrideName.isNotEmpty
        }

        private var shouldDisplayStickyTempTargetStopButton: Bool {
            state.isTempTargetEnabled && state.activeTempTargetName.isNotEmpty
        }

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        func formattedGlucose(glucose: Decimal) -> String {
            let formattedValue: String
            if state.units == .mgdL {
                formattedValue = Formatter.glucoseFormatter(for: state.units)
                    .string(from: glucose as NSDecimalNumber) ?? "\(glucose)"
            } else {
                formattedValue = glucose.formattedAsMmolL
            }
            return "\(formattedValue) \(state.units.rawValue)"
        }

        var body: some View {
            ZStack(alignment: .center, content: {
                VStack {
                    Picker("Adjustment Tabs", selection: $state.selectedTab) {
                        ForEach(Adjustments.Tab.allCases) { item in
                            Text(item.name).tag(item)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)

                    adjustmentsPager
                }
                .listSectionSpacing(10)
                .safeAreaInset(
                    edge: .bottom,
                    spacing: shouldDisplayStickyOverrideStopButton || shouldDisplayStickyTempTargetStopButton ? 30 : 0
                ) {
                    if shouldDisplayStickyOverrideStopButton, state.selectedTab == .overrides {
                        stickyStopOverrideButton
                    } else if shouldDisplayStickyTempTargetStopButton, state.selectedTab == .tempTargets {
                        stickyStopTempTargetButton
                    } else {
                        EmptyView()
                    }
                }
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .onAppear(perform: configureView)
                .navigationBarTitle("Adjustments")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        switch state.selectedTab {
                        case .overrides:
                            Button(action: {
                                showOverrideCreationSheet = true
                            }, label: {
                                HStack {
                                    Text("Add Override")
                                    Image(systemName: "plus")
                                }
                            })
                        case .tempTargets:
                            Button(action: {
                                showTempTargetCreationSheet = true
                            }, label: {
                                HStack {
                                    Text("Add Temp Target")
                                    Image(systemName: "plus")
                                }
                            })
                        }
                    }
                }
                .sheet(isPresented: $state.showOverrideEditSheet, onDismiss: {
                    Task {
                        await state.resetStateVariables()
                        state.showOverrideEditSheet = false
                    }

                }) {
                    if let override = selectedOverride {
                        EditOverrideForm(overrideToEdit: override, state: state)
                    }
                }
                .sheet(isPresented: $showOverrideCreationSheet, onDismiss: {
                    Task {
                        await state.resetStateVariables()
                        showOverrideCreationSheet = false
                    }
                }) {
                    AddOverrideForm(state: state)
                }
                .sheet(isPresented: $showTempTargetCreationSheet, onDismiss: {
                    Task {
                        await state.resetTempTargetState()
                        showTempTargetCreationSheet = false
                    }
                }) {
                    AddTempTargetForm(state: state)
                }
                .sheet(isPresented: $state.showTempTargetEditSheet, onDismiss: {
                    Task {
                        await state.resetTempTargetState()
                        state.showTempTargetEditSheet = false
                    }

                }) {
                    if let tempTarget = selectedTempTarget {
                        EditTempTargetForm(tempTargetToEdit: tempTarget, state: state)
                    }
                }
                .confirmationDialog("Override to Stop", isPresented: $showCancelOverrideConfirmDialog) {
                    Button("Stop", role: .destructive) {
                        Task {
                            // Save cancelled Override in OverrideRunStored Entity
                            // Cancel ALL active Override
                            await state.disableAllActiveOverrides(createOverrideRunEntry: true)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Stop the Override \"\(state.currentActiveOverride?.name ?? "")\"?")
                }
                .confirmationDialog("Temp Target to Stop", isPresented: $showCancelTempTargetConfirmDialog) {
                    Button("Stop", role: .destructive) {
                        Task {
                            // Save cancelled Temp Targets in TempTargetRunStored Entity
                            // Cancel ALL active Temp Targets
                            await state.disableAllActiveTempTargets(createTempTargetRunEntry: true)
                            // Update View
                            state.updateLatestTempTargetConfiguration()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Stop the Temp Target \"\(state.currentActiveTempTarget?.name ?? "")\"?")
                }
                .confirmationDialog(
                    "Activate Preset",
                    isPresented: presetActivationConfirmationBinding
                ) {
                    Button("Activate") {
                        if let activation = pendingPresetActivation {
                            activatePreset(activation)
                        }
                    }

                    Button("Cancel", role: .cancel) {
                        state.shouldDisplayPresetStartConfirmDialog = false
                        pendingPresetActivation = nil
                    }
                } message: {
                    if let activation = pendingPresetActivation {
                        Text(activation.confirmationMessage)
                    }
                }
            })
                .background(appState.trioBackgroundColor(for: colorScheme))
                .background(DisableInteractivePopGesture())
        }

        // MARK: - Horizontal Pager

        /// Native paging rather than a hand-rolled `DragGesture`. SwiftUI's gesture-priority
        /// modifiers (`gesture` / `simultaneousGesture` / `highPriorityGesture`) arbitrate only
        /// among SwiftUI gestures and cannot outrank the UIKit pan recognizer backing `List`,
        /// so the previous custom drag was unreliable. A paging `TabView` is driven by UIKit's
        /// own paging scroll view, which coordinates with the nested vertical lists natively.
        ///
        /// Preset rows keep their `swipeActions`, so a horizontal drag starting on a row is
        /// claimed by that row; paging responds everywhere else — section headers, empty space,
        /// and the running-adjustment banner.
        private var adjustmentsPager: some View {
            TabView(selection: $state.selectedTab) {
                ForEach(Adjustments.Tab.allCases) { tab in
                    adjustmentList(for: tab)
                        .tag(tab)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }

        @ViewBuilder private func adjustmentList(for tab: Adjustments.Tab) -> some View {
            List {
                switch tab {
                case .overrides: overrides()
                case .tempTargets: tempTargets()
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
        }

        @ViewBuilder func defaultText(for tab: Adjustments.Tab) -> some View {
            switch tab {
            case .overrides:
                Section {} header: {
                    Text("Add Preset or Override by tapping 'Add Override +' in the top right-hand corner of the screen.")
                        .textCase(nil)
                        .foregroundStyle(.secondary)
                }
            case .tempTargets:
                Section {} header: {
                    Text(
                        "Add Preset or Temp Target by tapping 'Add Temp Target +' in the top right-hand corner of the screen."
                    )
                    .textCase(nil)
                    .foregroundStyle(.secondary)
                }
            }
        }

        @ViewBuilder func currentActiveAdjustment(for tab: Adjustments.Tab) -> some View {
            switch tab {
            case .overrides:
                Section {
                    HStack {
                        Text("\(state.activeOverrideName) is running")

                        Spacer()
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(Color.primary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task {
                            /// To avoid editing the Preset when a Preset-Override is running we first duplicate the Preset-Override as a non-Preset Override
                            /// The currentActiveOverride variable in the State will update automatically via MOC notification
                            await state.duplicateOverridePresetAndCancelPreviousOverride()

                            /// selectedOverride is used for passing the chosen Override to the EditSheet so we have to set the updated currentActiveOverride to be the selectedOverride
                            selectedOverride = state.currentActiveOverride

                            /// Now we can show the Edit sheet
                            state.showOverrideEditSheet = true
                        }
                    }
                }
                .listRowBackground(Color.purple.opacity(0.8))
            case .tempTargets:
                Section {
                    HStack {
                        Text("\(state.activeTempTargetName) is running")

                        Spacer()
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(Color.primary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task {
                            /// To avoid editing the Preset when a Preset-Override is running we first duplicate the Preset-Override as a non-Preset Override
                            /// The currentActiveOverride variable in the State will update automatically via MOC notification
                            await state.duplicateTempTargetPresetAndCancelPreviousTempTarget()

                            /// selectedOverride is used for passing the chosen Override to the EditSheet so we have to set the updated currentActiveOverride to be the selectedOverride
                            selectedTempTarget = state.currentActiveTempTarget

                            /// Now we can show the Edit sheet
                            state.showTempTargetEditSheet = true
                        }
                    }
                }
                .listRowBackground(Color.loopGreen.opacity(0.8))
            }
        }

        var cancelAdjustmentButton: some View {
            switch state.selectedTab {
            case .overrides:
                Button(action: {
                    showCancelOverrideConfirmDialog = true
                }, label: {
                    Text("Stop Override")

                })
                    .frame(maxWidth: .infinity, alignment: .center)
                    .disabled(!state.isOverrideEnabled)
                    .listRowBackground(!state.isOverrideEnabled ? Color(.systemGray4) : Color(.systemRed))
                    .tint(.white)
            case .tempTargets:
                Button(action: {
                    showCancelTempTargetConfirmDialog = true
                }, label: {
                    Text("Stop Temp Target")

                })
                    .frame(maxWidth: .infinity, alignment: .center)
                    .disabled(!state.isTempTargetEnabled)
                    .listRowBackground(!state.isTempTargetEnabled ? Color(.systemGray4) : Color(.systemRed))
                    .tint(.white)
            }
        }

        func formattedTimeRemaining(_ timeInterval: TimeInterval) -> String {
            let totalSeconds = Int(timeInterval)
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            let seconds = totalSeconds % 60

            if hours > 0 {
                return "\(hours)h \(minutes)m \(seconds)s"
            } else if minutes > 0 {
                return "\(minutes)m \(seconds)s"
            } else {
                return "<1m"
            }
        }
    }
}

// MARK: Preset Activation Handling

extension Adjustments.RootView: View {
    enum PendingPresetActivation {
        case override(objectID: NSManagedObjectID, presetID: String?, name: String)
        case tempTarget(objectID: NSManagedObjectID, presetID: String?, name: String)

        var name: String {
            switch self {
            case let .override(_, _, name),
                 let .tempTarget(_, _, name):
                return name
            }
        }

        var adjustmentType: String {
            switch self {
            case .override:
                return String(localized: "Override")
            case .tempTarget:
                return String(localized: "Temp Target")
            }
        }

        var confirmationMessage: String {
            String(localized: "Start the \(adjustmentType) \"\(name)\"?", comment: "Confirmation message for starting a preset")
        }
    }

    private var presetActivationConfirmationBinding: Binding<Bool> {
        Binding(
            get: {
                state.requireAdjustmentsConfirmation &&
                    state.shouldDisplayPresetStartConfirmDialog &&
                    pendingPresetActivation != nil
            },
            set: { isPresented in
                if !isPresented {
                    state.shouldDisplayPresetStartConfirmDialog = false
                    pendingPresetActivation = nil
                }
            }
        )
    }

    func requestPresetActivation(_ activation: PendingPresetActivation) {
        if state.requireAdjustmentsConfirmation {
            pendingPresetActivation = activation
            state.shouldDisplayPresetStartConfirmDialog = true
        } else {
            activatePreset(activation)
        }
    }

    func activatePreset(_ activation: PendingPresetActivation) {
        Task {
            switch activation {
            case let .override(objectID, presetID, _):
                await state.enactOverridePreset(withID: objectID)

                await MainActor.run {
                    state.hideModal()
                    selectedOverridePresetID = presetID
                    showOverrideCheckmark = true
                    state.shouldDisplayPresetStartConfirmDialog = false
                    pendingPresetActivation = nil
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    showOverrideCheckmark = false
                }

            case let .tempTarget(objectID, presetID, _):
                await state.enactTempTargetPreset(withID: objectID)

                await MainActor.run {
                    selectedTempTargetPresetID = presetID
                    showTempTargetCheckmark = true
                    state.shouldDisplayPresetStartConfirmDialog = false
                    pendingPresetActivation = nil
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    showTempTargetCheckmark = false
                }
            }
        }
    }
}
