import Charts
import CoreData
import SwiftUI

let screenSize: CGRect = UIScreen.main.bounds
let calendar = Calendar.current

struct MainChartView: View {
    var geo: GeometryProxy
    var safeAreaSize: CGFloat
    var units: GlucoseUnits
    var hours: Int
    var highGlucose: Decimal
    var lowGlucose: Decimal
    var currentGlucoseTarget: Decimal
    var glucoseColorScheme: GlucoseColorScheme
    var screenHours: Int16
    var displayXgridLines: Bool
    var displayYgridLines: Bool
    var thresholdLines: Bool
    var state: Home.StateModel

    @State var basalProfiles: [BasalProfile] = []
    @State var preparedTempBasals: [(start: Date, end: Date, rate: Double)] = []
    @State var selection: Date? = nil

    @State var mainChartHasInitialized = false

    let now = Date.now

    private let context = CoreDataStack.shared.persistentContainer.viewContext

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.calendar) var calendar

    var upperLimit: Decimal {
        units == .mgdL ? 400 : 22.2
    }

    private var selectedGlucose: GlucoseStored? {
        guard let selection = selection else { return nil }
        let range = selection.addingTimeInterval(-150) ... selection.addingTimeInterval(150)
        return state.glucoseFromPersistence.first { $0.date.map(range.contains) ?? false }
    }

    private func findDetermination(in range: ClosedRange<Date>) -> OrefDetermination? {
        state.enactedAndNonEnactedDeterminations.first {
            $0.deliverAt ?? now >= range.lowerBound && $0.deliverAt ?? now <= range.upperBound
        }
    }

    var selectedCOBValue: OrefDetermination? {
        guard let selection = selection else { return nil }
        let range = selection.addingTimeInterval(-150) ... selection.addingTimeInterval(150)
        return findDetermination(in: range)
    }

    var selectedIOBValue: OrefDetermination? {
        guard let selection = selection else { return nil }
        let range = selection.addingTimeInterval(-150) ... selection.addingTimeInterval(150)
        return findDetermination(in: range)
    }

    private func timeForForecastIndex(_ index: Int32) -> Date {
        let anchor = state.determinationsFromPersistence.first?.deliverAt ?? .distantPast
        return anchor.addingTimeInterval(TimeInterval(index * 300))
    }

    var predictedIOBValue: Decimal? {
        guard let selection else { return nil }
        let tolerance: TimeInterval = 150
        let match = state.iobProjectionData.first {
            abs(timeForForecastIndex($0.iobProjectionValue.index).timeIntervalSince(selection)) <= tolerance
        }
        guard let match else { return nil }
        return match.iobProjectionValue.value?.decimalValue
    }

    var predictedCOBValue: Decimal? {
        guard let selection else { return nil }
        let tolerance: TimeInterval = 150
        let match = state.cobProjectionData.first {
            abs(timeForForecastIndex($0.cobProjectionValue.index).timeIntervalSince(selection)) <= tolerance
        }
        guard let match else { return nil }
        return match.cobProjectionValue.value?.decimalValue
    }

    var predictedGlucoseValue: Decimal? {
        guard let selection else { return nil }
        let tolerance: TimeInterval = 150
        let indices = 0 ..< min(state.minForecast.count, state.maxForecast.count)
        guard let matchIndex = indices.first(where: {
            abs(timeForForecastIndex(Int32($0)).timeIntervalSince(selection)) <= tolerance
        }) else { return nil }
        let minValue = Decimal(state.minForecast[matchIndex])
        let maxValue = Decimal(state.maxForecast[matchIndex])
        let midpoint = (minValue + maxValue) / 2
        return units == .mmolL ? midpoint.asMmolL : midpoint
    }

    var body: some View {
        VStack {
            ZStack {
                VStack(spacing: 5) {
                    dummyBasalChart
                    staticYAxisChart
                    Spacer()
                    dummyCobChart
                }

                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(spacing: 5) {
                            basalChart
                            mainChart
                            Spacer()
                            cobIobChart
                        }.onChange(of: screenHours) {
                            scroller.scrollTo("MainChart", anchor: .trailing)
                        }
                        .onChange(of: state.glucoseFromPersistence.last?.glucose) {
                            scroller.scrollTo("MainChart", anchor: .trailing)
                            state.updateStartEndMarkers()
                        }
                        .onChange(of: state.enactedAndNonEnactedDeterminations.first?.deliverAt) {
                            scroller.scrollTo("MainChart", anchor: .trailing)
                        }
                        .onChange(of: units) {
                            // TODO: - Refactor this to only update the Y Axis Scale
                            state.setupGlucoseArray()
                        }
                        .onAppear {
                            if !mainChartHasInitialized {
                                scroller.scrollTo("MainChart", anchor: .trailing)
                                state.updateStartEndMarkers()
                                calculateTempBasalsInBackground()
                                mainChartHasInitialized = true
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Main Chart with selection Popover

extension MainChartView {
    private var mainChart: some View {
        VStack {
            Chart {
                drawStartRuleMark()
                drawEndRuleMark()
                drawCurrentTimeMarker()

                GlucoseTargetsView(
                    targetProfiles: state.targetProfiles
                )

                OverrideView(
                    state: state,
                    overrides: state.overrides,
                    scheduledOverrides: state.scheduledOverrides,
                    overrideRunStored: state.overrideRunStored,
                    units: state.units,
                    viewContext: context
                )

                TempTargetView(
                    tempTargetStored: state.tempTargetStored,
                    tempTargetRunStored: state.tempTargetRunStored,
                    units: state.units,
                    viewContext: context
                )

                GlucoseChartView(
                    glucoseData: state.glucoseFromPersistence,
                    units: state.units,
                    highGlucose: state.highGlucose,
                    lowGlucose: state.lowGlucose,
                    currentGlucoseTarget: state.currentGlucoseTarget,
                    isSmoothingEnabled: state.isSmoothingEnabled,
                    glucoseColorScheme: state.glucoseColorScheme
                )

                InsulinView(
                    glucoseData: state.glucoseFromPersistence,
                    insulinData: state.insulinFromPersistence,
                    units: state.units,
                    bolusDisplayThreshold: state.bolusDisplayThreshold
                )

                CarbView(
                    glucoseData: state.glucoseFromPersistence,
                    units: state.units,
                    carbData: state.carbsFromPersistence,
                    fpuData: state.fpusFromPersistence,
                    minValue: units == .mgdL ? state.minYAxisValue : state.minYAxisValue
                        .asMmolL
                )

                ForecastView(
                    preprocessedData: state.preprocessedData,
                    minForecast: state.minForecast,
                    maxForecast: state.maxForecast,
                    units: state.units,
                    maxValue: state.maxYAxisValue,
                    forecastDisplayType: state.forecastDisplayType,
                    lastDeterminationDate: state.determinationsFromPersistence.first?.deliverAt ?? .distantPast
                )

                /// show glucose value when hovering over it
                if let selection {
                    SelectionPopoverView(
                        selectedGlucose: selectedGlucose,
                        selection: selection,
                        selectedIOBValue: selectedIOBValue,
                        selectedCOBValue: selectedCOBValue,
                        units: units,
                        highGlucose: highGlucose,
                        lowGlucose: lowGlucose,
                        currentGlucoseTarget: currentGlucoseTarget,
                        glucoseColorScheme: glucoseColorScheme,
                        isSmoothingEnabled: state.settingsManager.settings.smoothGlucose,
                        predictedIOB: predictedIOBValue,
                        predictedCOB: predictedCOBValue,
                        predictedGlucose: predictedGlucoseValue
                    )
                }
            }
            .id("MainChart")
            .frame(
                minHeight: geo.size.height * (0.28 - safeAreaSize)
            )
            .frame(width: fullWidth(viewWidth: screenSize.width))
            .chartXScale(domain: state.startMarker ... state.endMarker)
            .chartXAxis { mainChartXAxis }
            .chartYAxis { mainChartYAxis }
            .chartYAxis(.hidden)
            .chartXSelection(value: $selection)
            .chartYScale(
                domain: units == .mgdL ? state.minYAxisValue ... state.maxYAxisValue : state.minYAxisValue
                    .asMmolL ... state.maxYAxisValue.asMmolL
            )
            .chartLegend(.hidden)
            .chartForegroundStyleScale([
                "iob": Color.insulin,
                "uam": Color.uam,
                "zt": Color.zt,
                "cob": Color.orange
            ])
        }
    }
}
