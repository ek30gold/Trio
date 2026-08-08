import Charts
import Foundation
import SwiftUI

extension MainChartView {
    var cobIobChart: some View {
        Chart {
            drawCurrentTimeMarker()
            drawCOBIOBChart()

            if let selectedCOBValue {
                drawSelectedInnerPoint(
                    xValue: selectedCOBValue.deliverAt ?? Date.now,
                    yValue: Double(selectedCOBValue.cob),
                    axis: "COB"
                )
                drawSelectedOuterPoint(
                    xValue: selectedCOBValue.deliverAt ?? Date.now,
                    yValue: Double(selectedCOBValue.cob),
                    axis: "IOB",
                    color: Color.orange
                )
            }

            if let selectedIOBValue {
                let rawAmount = selectedIOBValue.iob?.doubleValue ?? 0
                let amount: Double = rawAmount > 0 ? rawAmount * 8 : rawAmount * 9

                drawSelectedInnerPoint(
                    xValue: selectedIOBValue.deliverAt ?? Date.now,
                    yValue: amount,
                    axis: "COB"
                )
                drawSelectedOuterPoint(
                    xValue: selectedIOBValue.deliverAt ?? Date.now,
                    yValue: amount,
                    axis: "IOB",
                    color: Color.darkerBlue
                )
            }
        }
        .chartForegroundStyleScale([
            "COB": Color.orange,
            "IOB": Color.darkerBlue
        ])
        .chartLegend(.hidden)
        .frame(minHeight: geo.size.height * 0.12 * chartHeightScale)
        .frame(width: fullWidth(viewWidth: screenSize.width))
        .chartXScale(domain: state.startMarker ... state.endMarker)
        .chartXSelection(value: $selection)
        .chartXAxis { basalChartXAxis }
        .chartYAxis { cobIobChartYAxis }
        .chartYScale(domain: combinedYDomain())
    }

    func combinedYDomain() -> ClosedRange<Double> {
        let iobMin = scaleIobAmountForChart(state.minValueIobChart)
        let iobMax = scaleIobAmountForChart(state.maxValueIobChart)
        let minValue = min(state.minValueCobChart, iobMin)
        let maxValue = max(state.maxValueCobChart, iobMax)
        return Double(minValue) ... Double(maxValue)
    }

    private func drawSelectedInnerPoint(xValue: Date, yValue: Double, axis: String) -> some ChartContent {
        PointMark(
            x: .value("Time", xValue, unit: .minute),
            y: .value("Value", yValue)
        )
        .symbolSize(CGSize(width: 6, height: 6))
        .foregroundStyle(Color.primary)
        .position(by: .value("Axis", axis))
    }

    private func drawSelectedOuterPoint(xValue: Date, yValue: Double, axis: String, color: Color) -> some ChartContent {
        PointMark(
            x: .value("Time", xValue, unit: .minute),
            y: .value("Value", yValue)
        )
        .symbolSize(CGSize(width: 15, height: 15))
        .foregroundStyle(color.opacity(0.8))
        .position(by: .value("Axis", axis))
    }

    /// Scales IOB amounts for chart display.
    ///
    /// As IOB and COB share the same Y axis and COB is usually >> IOB,
    /// we need to visually weigh IOB by multiplying it by a scaling factor:
    ///
    /// - Parameter rawAmount: The unscaled IOB amount
    /// - Returns: The scaled IOB amount for visual representation
    private func scaleIobAmountForChart<T: Numeric & Comparable>(_ rawAmount: T) -> T where T: ExpressibleByIntegerLiteral {
        rawAmount > 0 ? rawAmount * 8 : rawAmount * 9
    }

    @ChartContentBuilder
    func drawCOBIOBChart() -> some ChartContent {
        // Filter out duplicate entries by `deliverAt`,
        // We sometimes get two determinations when editing carbs, one without the entry-to-be-edited and then another one after editing the entry.
        // We are fetching determinations in descending order, so the first one is the latter determination (with correct amounts), so keeping the first one encountered.
        var seenDates = Set<Date>()
        let filteredDeterminations = state.enactedAndNonEnactedDeterminations.filter { item in
            if let date = item.deliverAt {
                if seenDates.contains(date) {
                    // Already seen this date – filter it out.
                    return false
                } else {
                    seenDates.insert(date)
                    return true
                }
            }
            return true
        }
        // Sort ascending by deliverAt for proper AreaMark continuous fill rendering
        .sorted { ($0.deliverAt ?? .distantPast) < ($1.deliverAt ?? .distantPast) }

        ForEach(filteredDeterminations) { item in

            // MARK: - COB line and area mark

            let amountCOB = Int(item.cob)
            let date: Date = item.deliverAt ?? Date()

            LineMark(x: .value("Time", date), y: .value("Value", amountCOB))
                .foregroundStyle(by: .value("Type", "COB"))
                .position(by: .value("Axis", "COB"))
            AreaMark(x: .value("Time", date), y: .value("Value", amountCOB))
                .foregroundStyle(by: .value("Type", "COB"))
                .position(by: .value("Axis", "COB"))
                .opacity(0.2)

            // MARK: - IOB line and area mark

            let rawAmount = item.iob?.doubleValue ?? 0
            let amountIOB: Double = scaleIobAmountForChart(rawAmount)

            AreaMark(x: .value("Time", date), y: .value("Amount", amountIOB))
                .foregroundStyle(by: .value("Type", "IOB"))
                .position(by: .value("Axis", "IOB"))
                .opacity(0.2)
            LineMark(x: .value("Time", date), y: .value("Amount", amountIOB))
                .foregroundStyle(by: .value("Type", "IOB"))
                .position(by: .value("Axis", "IOB"))
        }

        // MARK: - Projected future COB/IOB marks

        // Anchor projections on the same historical data source (filteredDeterminations) used above.
        // This ensures projected points are chronologically aligned with historical points.
        let historicalAnchor = filteredDeterminations.last?.deliverAt
        let projectedDate: (Int32) -> Date? = { index in
            historicalAnchor.map { $0.addingTimeInterval(TimeInterval(index * 300)) }
        }

        if let projectionAnchorDate = projectedDate(0), projectionAnchorDate > Date(timeIntervalSinceNow: TimeInterval(hours: -24)) {
            let filteredIobProjectionData = state.iobProjectionData
                .filter { projectedDate($0.iobProjectionValue.index) ?? .distantFuture < state.endMarker }
                .sorted { $0.iobProjectionValue.index < $1.iobProjectionValue.index }

            ForEach(filteredIobProjectionData, id: \.id) { entry in

                // MARK: - Projected IOB line and area mark

                if let projectedDate = projectedDate(entry.iobProjectionValue.index) {
                    let rawAmount = entry.iobProjectionValue.value?.doubleValue ?? 0
                    let amountIOB: Double = scaleIobAmountForChart(rawAmount)

                    AreaMark(x: .value("Time", projectedDate), y: .value("Amount", amountIOB))
                        .foregroundStyle(by: .value("Type", "IOB"))
                        .position(by: .value("Axis", "IOB"))
                        .opacity(0.2)
                    LineMark(x: .value("Time", projectedDate), y: .value("Amount", amountIOB))
                        .foregroundStyle(by: .value("Type", "IOB"))
                        .position(by: .value("Axis", "IOB"))
                }
            }

            let filteredCobProjectionData = state.cobProjectionData
                .filter { projectedDate($0.cobProjectionValue.index) ?? .distantFuture < state.endMarker }
                .sorted { $0.cobProjectionValue.index < $1.cobProjectionValue.index }

            ForEach(filteredCobProjectionData, id: \.id) { entry in

                // MARK: - Projected COB line and area mark

                if let projectedDate = projectedDate(entry.cobProjectionValue.index) {
                    let amountCOB = Int(entry.cobProjectionValue.value?.doubleValue ?? 0)

                    LineMark(x: .value("Time", projectedDate), y: .value("Value", amountCOB))
                        .foregroundStyle(by: .value("Type", "COB"))
                        .position(by: .value("Axis", "COB"))
                    AreaMark(x: .value("Time", projectedDate), y: .value("Value", amountCOB))
                        .foregroundStyle(by: .value("Type", "COB"))
                        .position(by: .value("Axis", "COB"))
                        .opacity(0.2)
                }
            }
        }
    }
}
