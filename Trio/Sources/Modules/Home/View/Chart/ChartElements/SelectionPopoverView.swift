import Charts
import Foundation
import SwiftUI

struct SelectionPopoverView: ChartContent {
    let selectedGlucose: GlucoseStored?
    let selection: Date
    let selectedIOBValue: OrefDetermination?
    let selectedCOBValue: OrefDetermination?
    let units: GlucoseUnits
    let highGlucose: Decimal
    let lowGlucose: Decimal
    let currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    let isSmoothingEnabled: Bool
    let predictedIOB: Decimal?
    let predictedCOB: Decimal?

    private var glucoseToDisplay: Decimal? {
        guard let selectedGlucose else { return nil }
        return units == .mgdL ? Decimal(selectedGlucose.glucose) : Decimal(selectedGlucose.glucose).asMmolL
    }

    private var pointMarkColor: Color? {
        guard let selectedGlucose else { return nil }
        let hardCodedLow = Decimal(55)
        let hardCodedHigh = Decimal(220)
        let isDynamicColorScheme = glucoseColorScheme == .dynamicColor

        return Trio.getDynamicGlucoseColor(
            glucoseValue: Decimal(selectedGlucose.glucose),
            highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
            lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }

    var body: some ChartContent {
        RuleMark(x: .value("Selection", selection, unit: .minute))
            .foregroundStyle(Color.tabBar)
            .offset(yStart: isSmoothingEnabled ? 90 : 70)
            .lineStyle(.init(lineWidth: 2))
            .annotation(
                position: .top,
                alignment: .center,
                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
            ) {
                selectionPopover
            }

        if let selectedGlucose, let glucoseToDisplay, let pointMarkColor {
            PointMark(
                x: .value("Time", selectedGlucose.date ?? selection, unit: .minute),
                y: .value("Value", glucoseToDisplay)
            )
            .zIndex(-1)
            .symbolSize(CGSize(width: 15, height: 15))
            .foregroundStyle(pointMarkColor)

            PointMark(
                x: .value("Time", selectedGlucose.date ?? selection, unit: .minute),
                y: .value("Value", glucoseToDisplay)
            )
            .zIndex(-1)
            .symbolSize(CGSize(width: 6, height: 6))
            .foregroundStyle(Color.primary)
        }
    }

    @ViewBuilder var selectionPopover: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: "clock")
                Text(selection.formatted(.dateTime.hour().minute(.twoDigits)))
                    .font(.body).bold()
            }
            .font(.body).padding(.bottom, 2)

            if let selectedGlucose, let glucoseToDisplay, let pointMarkColor {
                HStack {
                    Text("CGM: ") + Text(glucoseToDisplay.description).bold() + Text(" \(units.rawValue)")
                }
                .foregroundStyle(pointMarkColor)
                .font(.body)

                if isSmoothingEnabled, let smoothedGlucose = selectedGlucose.smoothedGlucose {
                    var smoothedGlucoseToDisplay: Decimal {
                        units == .mgdL ? smoothedGlucose.decimalValue : smoothedGlucose.decimalValue.asMmolL
                    }
                    HStack {
                        Image(systemName: "sparkles")
                        Text(smoothedGlucoseToDisplay.description) + Text(" \(units.rawValue)")
                    }.font(.body)
                }
            }

            if let selectedIOBValue, let iob = selectedIOBValue.iob {
                HStack {
                    Image(systemName: "syringe.fill").frame(width: 15)
                    Text(Formatter.decimalFormatterWithTwoFractionDigits.string(from: iob) ?? "")
                        .bold()
                        + Text(String(localized: " U", comment: "Insulin unit"))
                }
                .foregroundStyle(Color.insulin).font(.body)
            }

            if let selectedCOBValue {
                HStack {
                    Image(systemName: "fork.knife").frame(width: 15)
                    Text(Formatter.integerFormatter.string(from: selectedCOBValue.cob as NSNumber) ?? "")
                        .bold()
                        + Text(String(localized: " g", comment: "gram of carbs"))
                }
                .foregroundStyle(Color.orange).font(.body)
            }

            if let predictedIOB {
                HStack {
                    Image(systemName: "syringe.fill").frame(width: 15)
                    Text(Formatter.decimalFormatterWithTwoFractionDigits.string(from: NSDecimalNumber(decimal: predictedIOB)) ?? "")
                        .bold()
                        + Text(String(localized: " U", comment: "Insulin unit"))
                }
                .foregroundStyle(Color.insulin).font(.body)
                .opacity(0.6)
            }

            if let predictedCOB {
                HStack {
                    Image(systemName: "fork.knife").frame(width: 15)
                    Text(Formatter.integerFormatter.string(from: NSDecimalNumber(decimal: predictedCOB)) ?? "")
                        .bold()
                        + Text(String(localized: " g", comment: "gram of carbs"))
                }
                .foregroundStyle(Color.orange).font(.body)
                .opacity(0.6)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.chart.opacity(0.85))
                .shadow(color: Color.secondary, radius: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary, lineWidth: 2)
                )
        }
    }
}
