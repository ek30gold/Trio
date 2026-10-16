#!/usr/bin/env bash
# Usage: check_features.sh [<git ref>|WORKTREE]   (default HEAD)
# Run from inside the Trio repo (or any dir; it cd's to the repo root).
# Data rows: sha<TAB>path<TAB>anchor.  Anchor prefixed with "!ABSENT!" must NOT exist (removal hunks).
REF="${1:-HEAD}"
cd "$(git rev-parse --show-toplevel)" || exit 2
total=0; failed=0
while IFS=$'\t' read -r sha path anchor; do
  [ -z "$sha" ] && continue
  case "$sha" in \#*) continue;; esac
  want=present
  if [[ "$anchor" == '!ABSENT!'* ]]; then want=absent; anchor="${anchor#!ABSENT!}"; fi
  if [ "$REF" = WORKTREE ]; then
    if [ -f "$path" ] && grep -F -q -e "$anchor" -- "$path"; then found=1; else found=0; fi
  else
    if git grep -F -q -e "$anchor" "$REF" -- "$path" 2>/dev/null; then found=1; else found=0; fi
  fi
  total=$((total+1))
  if { [ $want = present ] && [ $found = 1 ]; } || { [ $want = absent ] && [ $found = 0 ]; }; then
    echo "PASS $sha [$want] $path :: $anchor"
  else
    echo "FAIL $sha [$want] $path :: $anchor"; failed=$((failed+1))
  fi
done <<'DATA'
2098e216	.github/workflows/fork_ci.yml	name: "Fork CI: build & unit tests"
2098e216	.github/workflows/fork_ci.yml	# Fork-owned CI: compile + unit tests without a local Mac.
2098e216	.github/workflows/fork_ci.yml	name: Build for testing
48058846	Trio/Sources/Modules/History/HistoryStateModel+Deletion/HistoryStateModel+Carbs.swift	skipRecompute: Bool = false
48058846	Trio/Sources/Modules/History/HistoryStateModel+Deletion/HistoryStateModel+Carbs.swift	if !skipRecompute {
48058846	Trio/Sources/Modules/History/HistoryStateModel+Deletion/HistoryStateModel+CarbEditing.swift	skipRecompute: true
48058846	Trio/Sources/Modules/History/HistoryStateModel+Deletion/HistoryStateModel+CarbEditing.swift	try await deleteCarbs(treatmentObjectID, isFpuOrComplexMeal: true, skipRecompute: skipRecompute)
31d4d52e	Trio/Sources/Models/WatchMessageKeys.swift	static let eventualBG = "eventualBG"
31d4d52e	Trio/Sources/Models/WatchState.swift	hasher.combine(eventualBG)
31d4d52e	Trio/Sources/Models/WatchState.swift	lhs.eventualBG == rhs.eventualBG &&
31d4d52e	Trio/Sources/Services/WatchManager/AppleWatchManager.swift	watchState.eventualBG = "\(eventualGlucose.formattedAsMmolL)"
31d4d52e	Trio/Sources/Services/WatchManager/AppleWatchManager.swift	WatchMessageKeys.eventualBG: state.eventualBG ?? "",
31d4d52e	Trio Watch App Extension/WatchState.swift	if let eventualBG = message[WatchMessageKeys.eventualBG] as? String {
31d4d52e	Trio Watch App Extension/Views/GlucoseTrendView.swift	Text(isWatchStateDated ? "--" : (state.eventualBG ?? "--"))
4a349427	Trio/Sources/Modules/Adjustments/View/AdjustmentsRootView.swift	private struct DisableInteractivePopGesture: UIViewControllerRepresentable {
4a349427	Trio/Sources/Modules/Adjustments/View/AdjustmentsRootView.swift	private var adjustmentsPager: some View {
4a349427	Trio/Sources/Modules/Adjustments/View/AdjustmentsRootView.swift	.tabViewStyle(.page(indexDisplayMode: .never))
4a349427	Trio/Sources/Modules/Adjustments/View/AdjustmentsRootView.swift	@ViewBuilder private func adjustmentList(for tab: Adjustments.Tab) -> some View {
4a349427	Trio/Sources/Modules/Adjustments/View/Overrides/AdjustmentsRootView+Overrides.swift	currentActiveAdjustment(for: .overrides)
4a349427	Trio/Sources/Modules/Adjustments/View/TempTargets/AdjustmentsRootView+TempTargets.swift	currentActiveAdjustment(for: .tempTargets)
69d0c44a	Trio/Sources/Modules/Home/View/Chart/ChartElements/ChartSelectionRow.swift	static func glucoseForecastMidpoint(
69d0c44a	Trio/Sources/Modules/Home/View/Chart/ChartElements/ChartSelectionRow.swift	static func iobProjection(at date: Date, in points: [ProjectionPoint]) -> Double?
69d0c44a	Trio/Sources/Modules/Home/View/Chart/ChartElements/ChartSelectionRow.swift	private func predictedOpacity(measured: String?) -> Double {
69d0c44a	Trio/Sources/Modules/Home/View/Chart/ChartElements/ChartSelectionRow.swift	let predictedGlucose: Decimal?
69d0c44a	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	private func predictedValues(at date: Date) -> (iob: Decimal?, cob: Decimal?, glucose: Decimal?) {
69d0c44a	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	private var glucoseForecastAnchor: Date {
69d0c44a	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	let hasProjection = predicted.iob != nil || predicted.cob != nil || predicted.glucose != nil
88c6d19a	.github/workflows/fork_ci.yml	name: Run tests
1180d594	CLAUDE.md	Verified example: `LiveActivity/Views`
1180d594	CLAUDE.md	synchronized folders (new in v1.0)
7989fb66	docs/UPSTREAM_SYNC_PLAN.md	# Upstream Sync Plan — ek30gold/Trio → nightscout/Trio
7989fb66	docs/port/PORT_TO_V1.0_PLAN.md	# Port to Trio v1.0 — execution plan
7989fb66	docs/port/TRIAGE-RESULTS.md	# Layer 1 triage results — all 8 features vs v1.0
7989fb66	docs/port/patches/01-scheduled-overrides.patch	diff --git a/Trio/Sources/APS/Storage/OverrideStorage.swift b/Trio/Sources/APS/Storage/OverrideStorage.swift
7989fb66	docs/port/patches/01b-scheduled-overrides-BUGFIX.patch	diff --git a/Model/Classes+Properties/OverrideStored+CoreDataProperties.swift
7989fb66	docs/port/patches/02-favorite-foods-meal-presets.patch	diff --git a/CLAUDE.md b/CLAUDE.md
7989fb66	docs/port/patches/05-watch-eventual-bg.patch	diff --git a/Trio Watch App Extension/Views/GlucoseTrendView.swift
7989fb66	docs/port/patches/09-basal-rate-live-activity-widget.patch	diff --git a/LiveActivity/LiveActivity.swift
4df1fbe2	docs/port/patches/XX-modern-ui-DROPPED-not-ported.patch	diff --git a/Trio.xcodeproj/project.pbxproj
2748b101	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	.map { Decimal($0) }
2748b101	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	ambiguous between Decimal's own Double/floatLiteral inits
52ba3451	LiveActivity/Views/WidgetItems/LiveActivityBasalRateView.swift	struct LiveActivityBasalRateView: View {
52ba3451	LiveActivity/Views/LiveActivityView.swift	LiveActivityBasalRateView(
52ba3451	LiveActivity/LiveActivity.swift	isTempBasalActive: true,
52ba3451	Trio/Sources/Modules/LiveActivitySettings/View/LiveActivityWidgetConfiguration.swift	private var basalRatePreview: some View {
52ba3451	Trio/Sources/Modules/LiveActivitySettings/View/LiveActivityWidgetConfiguration.swift	comment: "Live Activity widget icon label for Basal Rate"
52ba3451	Trio/Sources/Services/LiveActivity/Data/BasalData.swift	struct BasalData {
52ba3451	Trio/Sources/Services/LiveActivity/Data/DataManager.swift	func fetchAndMapBasal() async throws -> ActiveTempBasal?
52ba3451	Trio/Sources/Services/LiveActivity/LiveActitiyAttributes.swift	let isInsulinSuspended: Bool
52ba3451	Trio/Sources/Services/LiveActivity/LiveActivityAttributes+Helper.swift	basalRate: basal?.rate, // stays nil when unknown
52ba3451	Trio/Sources/Services/LiveActivity/LiveActivityManager.swift	private func loadBasal() async {
52ba3451	Trio.xcodeproj/project.pbxproj	BasalData.swift in Sources
0213a809	Model/Classes+Properties/OverrideStored+CoreDataProperties.swift	@NSManaged var isScheduled: Bool
0213a809	Model/Classes+Properties/TempTargetStored+CoreDataProperties.swift	@NSManaged var isScheduled: Bool
0213a809	Model/TrioCoreDataPersistentContainer.xcdatamodeld/TrioCoreDataPersistentContainer.xcdatamodel/contents	<attribute name="isScheduled" optional="YES" attributeType="Boolean" defaultValueString="NO" usesScalarValueType="YES"/>
0213a809	Trio/Sources/APS/ScheduledOverrideManager.swift	final class BaseScheduledOverrideManager: ScheduledOverrideManager, Injectable {
0213a809	Trio/Sources/APS/ScheduledOverrideManager.swift	static let activationGracePeriod: TimeInterval = 15 * 60
0213a809	Trio/Sources/APS/FetchGlucoseManager.swift	await self.scheduledOverrideManager.catchUpOnDueScheduledTempTargets()
0213a809	Trio/Sources/APS/Storage/OverrideStorage.swift	func fetchDueScheduledOverrides(asOf date: Date) async throws -> [NSManagedObjectID]
0213a809	Trio/Sources/APS/Storage/TempTargetsStorage.swift	func fetchDueScheduledTempTargets(asOf date: Date) async throws -> [NSManagedObjectID]
0213a809	Trio/Sources/Assemblies/APSAssembly.swift	container.register(ScheduledOverrideManager.self) { r in BaseScheduledOverrideManager(resolver: r) }
0213a809	Trio/Sources/Models/Override.swift	var isScheduled: Bool = false
0213a809	Trio/Sources/Modules/Adjustments/AdjustmentsStateModel+Extensions/AdjustmentsStateModel+Overrides.swift	func cancelScheduledOverride(_ objectID: NSManagedObjectID) async {
0213a809	Trio/Sources/Modules/Adjustments/AdjustmentsStateModel+Extensions/AdjustmentsStateModel+TempTargets.swift	func sendScheduledTempTargetNotification(name: String, scheduledDate: Date) async {
0213a809	Trio/Sources/Modules/Adjustments/View/Overrides/EditOverrideForm.swift	private func scheduleOverride() {
0213a809	Trio/Sources/Modules/Adjustments/View/TempTargets/EditTempTargetForm.swift	private func scheduleTempTarget() {
0213a809	Trio/Sources/Services/Adjustments/AdjustmentManager.swift	case scheduled
0213a809	Trio.xcodeproj/project.pbxproj	ScheduledOverrideManager.swift in Sources
0213a809	Trio.xcodeproj/project.pbxproj	ScheduledOverrideTests.swift in Sources
0213a809	TrioTests/CoreDataTests/ScheduledOverrideTests.swift	@Suite("Scheduled Override Tests", .serialized) struct ScheduledOverrideTests: Injectable {
edc08b92	Trio/Sources/Modules/Treatments/TreatmentsStateModel.swift	@MainActor private var forecastGeneration: UInt64 = 0
edc08b92	Trio/Sources/Modules/Treatments/TreatmentsStateModel.swift	discarding superseded forecast simulation
edc08b92	Trio/Sources/Modules/Treatments/View/ForecastChart.swift	let displayedCOB = state.simulatedDetermination?.cob ?? Decimal(state.cob)
edc08b92	Trio/Sources/Modules/Treatments/View/ForecastChart.swift	let displayedIOB = state.simulatedDetermination?.iob ?? state.iob
df2434d3	Model/Classes+Properties/MealPresetStored+CoreDataProperties.swift	@NSManaged var orderPosition: Int16
df2434d3	Model/Classes+Properties/MealPresetStored+CoreDataProperties.swift	@NSManaged var note: String?
df2434d3	Model/TrioCoreDataPersistentContainer.xcdatamodeld/TrioCoreDataPersistentContainer.xcdatamodel/contents	<attribute name="orderPosition" optional="YES" attributeType="Integer 16" defaultValueString="0"/>
df2434d3	Trio/Sources/Localizations/Main/Localizable.xcstrings	"Serving size or notes (optional)" : {
df2434d3	Trio/Sources/Modules/Treatments/TreatmentsStateModel.swift	func reorderMealPreset(from source: IndexSet, to destination: Int) {
df2434d3	Trio/Sources/Modules/Treatments/View/MealPreset/ManageMealPresetsView.swift	struct ManageMealPresetsView: View {
df2434d3	Trio/Sources/Modules/Treatments/View/MealPreset/MealPresetView.swift	sortDescriptors: [NSSortDescriptor(key: "orderPosition", ascending: true)]
df2434d3	Trio/Sources/Router/Screen.swift	case manageMealPresets
df2434d3	Trio.xcodeproj/project.pbxproj	ManageMealPresetsView.swift in Sources
acd0b17d	Trio/Sources/APS/ScheduledOverrideManager.swift	try await adjustmentManager.activateTempTarget(.objectID(id), source: .scheduled)
acd0b17d	Trio/Sources/APS/ScheduledOverrideManager.swift	`isScheduled` deliberately stays true across this
acd0b17d	Trio/Sources/APS/ScheduledOverrideManager.swift	`isScheduled` true until activation has actually succeeded
5787ec71	Trio/Sources/Modules/Home/View/Chart/MainChartView.swift	// No reading resolves here: a scrub past the newest reading, into the forecast
5787ec71	Trio/Sources/Modules/Home/View/Chart/MainChartView.swift	let x = xPosition(for: selection)
f8b3ad2f	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	@ViewBuilder private var basalRateItem: some View {
89154db0	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	private func basalString(for delivery: ScheduledBasalInference.Delivery?) -> String? {
89154db0	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	let delivery = state.activeBasalDelivery
f8b3ad2f	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	Text("MaxIOB: 0 U")
89154db0	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	if let apsManager = state.apsManager, !apsManager.isSuspended, apsManager.isScheduledBasal != nil,
f8b3ad2f	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	.accessibilityLabel(Text("Basal rate"))
89154db0	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	let opacity = isScheduledDelivery(delivery) ? 0.6 : 1.0
f8b3ad2f	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	comment: "Manual Temp basal"
f8b3ad2f	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	basalRateItem
f8b3ad2f	Trio/Sources/Modules/Home/View/HomeRootView+MealPanel.swift	String(localized: " U/hr", comment: "Unit per hour with space") +
f8b3ad2f	Trio/Sources/Modules/Home/View/HomeRootView.swift	!ABSENT!currentBasalRateLabel
f8b3ad2f	Trio/Sources/Modules/Home/View/HomeRootView.swift	!ABSENT!.glassMaterialFill(Capsule())
f8b3ad2f	Trio/Sources/Modules/Home/View/HomeRootView.swift	!ABSENT!centered in the basal
024d28dc	Trio/Sources/Models/GlucoseAlerts/DeviceAlertSeverity.swift	var interruptionLevel: Alert.InterruptionLevel {
024d28dc	Trio/Sources/Services/Alerts/DeviceAlertsStore.swift	enum AdjustableAlert: String, CaseIterable, Codable, Identifiable {
024d28dc	Trio/Sources/Services/Alerts/DeviceAlertsStore.swift	@Published private(set) var tierOverrides: [String: DeviceAlertSeverity]
024d28dc	Trio/Sources/Services/Alerts/DeviceAlertsStore.swift	static let notLoopingDelayOptions: [Int] = [20, 30, 45, 60, 90, 120]
024d28dc	Trio/Sources/Services/Alerts/DeviceAlertsStore.swift	overridesKey: String = "trio.deviceAlertTierOverrides.v1",
024d28dc	Trio/Sources/Services/Alerts/DeviceAlertsStore.swift	func tier(for entry: Alert.CatalogEntry) -> DeviceAlertSeverity? {
024d28dc	Trio/Sources/Services/Alerts/DeviceAlertsStore.swift	func setNotLoopingDelay(minutes: Int) {
024d28dc	Trio/Sources/Services/Alerts/DeviceAlertsStore.swift	tierOverrides = overrides.filter { AdjustableAlert(rawValue: $0.key) != nil }
024d28dc	Trio/Sources/Services/Alerts/AlertColdStartReplay.swift	tierFor: (Alert.CatalogEntry) -> DeviceAlertSeverity? = { DeviceAlertSeverity(level: $0.interruptionLevel) }
024d28dc	Trio/Sources/Services/Alerts/AlertColdStartReplay.swift	let catalogTier = catalogEntry.flatMap(tierFor)
024d28dc	Trio/Sources/Services/Alerts/NotLoopingMonitor.swift	private let delayMinutes: () -> Int
024d28dc	Trio/Sources/Services/Alerts/NotLoopingMonitor.swift	delayMinutes = { DeviceAlertsStore.shared.notLoopingDelayMinutes }
024d28dc	Trio/Sources/Services/Alerts/NotLoopingMonitor.swift	delayMinutes: @escaping () -> Int = { DeviceAlertsStore.defaultNotLoopingDelayMinutes }
89154db0	Trio/Sources/Services/Alerts/NotLoopingMonitor.swift	let warnings = Self.warningSchedule(firstWarningAfter: delayMinutes())
024d28dc	Trio/Sources/Services/Alerts/NotLoopingMonitor.swift	!ABSENT!gracePeriodMinutes: Int = 20
024d28dc	Trio/Sources/Services/Alerts/TrioAlertManager.swift	guard let tier = DeviceAlertsStore.shared.tier(for: entry) else { return }
024d28dc	Trio/Sources/Services/Alerts/TrioAlertManager.swift	entry _: Alert.CatalogEntry,
024d28dc	Trio/Sources/Services/Alerts/TrioAlertManager.swift	interruptionLevel: config.overridesSilenceAndDND ? .critical : config.severity.interruptionLevel,
024d28dc	Trio/Sources/Services/Alerts/TrioAlertManager.swift	tierFor: { DeviceAlertsStore.shared.tier(for: $0) }
024d28dc	Trio/Sources/Services/Alerts/TrioAlertManager.swift	DeviceAlertsStore.shared.tier(for: entry) == tier
024d28dc	Trio/Sources/Services/Alerts/TrioAlertManager.swift	!ABSENT!DeviceAlertSeverity(level: entry.interruptionLevel) == tier
024d28dc	Trio/Sources/Services/Alerts/TrioAlertManager.swift	!ABSENT!let tier = DeviceAlertSeverity(level: entry.interruptionLevel) else { return }
024d28dc	Trio/Sources/Modules/DeviceAlarms/View/DeviceAlarmEditorView.swift	struct AdjustableAlertDetailView: View {
024d28dc	Trio/Sources/Modules/DeviceAlarms/View/DeviceAlarmEditorView.swift	AdjustableAlertDetailView(store: store, alert: adjustable)
024d28dc	Trio/Sources/Modules/DeviceAlarms/View/DeviceAlarmEditorView.swift	String(localized: "Alert After"),
024d28dc	Trio/Sources/Modules/DeviceAlarms/View/DeviceAlarmEditorView.swift	String(format: String(localized: "%d min"), minutes)
024d28dc	Trio/Sources/Localizations/Main/Localizable.xcstrings	"Alert After" : {
024d28dc	Trio/Sources/Localizations/Main/Localizable.xcstrings	"Tap an unlocked alert to move it to another tier. Pump and sensor alarms keep their built-in tier."
024d28dc	Trio/Sources/Localizations/Main/Localizable.xcstrings	"Changes take effect after Trio's next successful loop."
024d28dc	TrioTests/NotLoopingMonitorTests.swift	func customDelayMinutesDrivesTriggerAndBody() {
024d28dc	TrioTests/NotLoopingMonitorTests.swift	func delayMinutesIsReReadOnEveryReschedule() {
024d28dc	TrioTests/DeviceAlertsStoreTests.swift	func lockedConceptIgnoresOverrides() throws {
024d28dc	TrioTests/DeviceAlertsStoreTests.swift	func overridesAndDelayPersist() {
024d28dc	TrioTests/AlertColdStartReplayTests.swift	func tierOverrideSetsLevel() {
024d28dc	TrioTests/AlertColdStartReplayTests.swift	func tierOverrideObeysSnooze() {
89154db0	Trio/Sources/Services/Alerts/DeviceAlertsStore.swift	adjustable != .notLooping || entry.identifier.alertIdentifier == "loop.notActive",
89154db0	Trio/Sources/Services/Alerts/NotLoopingMonitor.swift	private static func warningSchedule(firstWarningAfter delay: Int) -> [Int] {
4176e012	Trio/Sources/Modules/Adjustments/View/Overrides/AdjustmentsRootView+Overrides.swift	ForEach(state.scheduledOverrides, id: \.objectID) { override in
4176e012	Trio/Sources/Modules/Adjustments/View/TempTargets/AdjustmentsRootView+TempTargets.swift	ForEach(state.scheduledTempTargets, id: \.objectID) { tempTarget in
DATA
echo "TOTAL: $total anchors, $failed failed"
[ "$failed" -eq 0 ]
