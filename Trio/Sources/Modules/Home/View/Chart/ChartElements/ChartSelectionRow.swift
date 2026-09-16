import Foundation
import SwiftUI

/// Selection marker/readout color for a glucose value, shared with the shell's overlay dot.
func selectionMarkColor(
    for glucose: GlucoseStored,
    highGlucose: Decimal,
    lowGlucose: Decimal,
    currentGlucoseTarget: Decimal,
    glucoseColorScheme: GlucoseColorScheme
) -> Color {
    let hardCodedLow = Decimal(55)
    let hardCodedHigh = Decimal(220)
    let isDynamicColorScheme = glucoseColorScheme == .dynamicColor

    return Trio.getDynamicGlucoseColor(
        glucoseValue: Decimal(glucose.glucose),
        highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
        lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
        targetGlucose: currentGlucoseTarget,
        glucoseColorScheme: glucoseColorScheme
    )
}

/// Resolves a scrub timestamp to the records it points at, so the chart's marks and the
/// Home meal slot's readout always describe the same reading.
enum ChartSelectionLookup {
    /// Half-width of the lookup window. Pairs with the 300 s scrub snap in
    /// `MainChartView.updateSelection`, so a snapped selection lands on exactly one reading.
    static let window: TimeInterval = 150

    /// How long the readout survives a scrub that resolves to nothing: long enough to bridge
    /// a missing reading, short enough not to feel stuck once the finger lifts.
    static let decay: TimeInterval = 0.6

    /// The fade the readout swaps in and out with. Quick, because it answers the finger:
    /// anything slower reads as lag between the touch and the values it asked for.
    ///
    /// Applied to the meal slot itself, keyed on whether a readout is showing: scoping it
    /// there keeps the transaction off everything else that changes in the same frame, which
    /// a `withAnimation` at the mutation site could not do.
    static let readoutFade: Animation = .easeOut(duration: 0.12)

    /// How far a held determination may sit from the selection before it is dropped instead:
    /// two cadences, so a hole is bridged but a jump elsewhere on the chart is not.
    static let determinationHold: TimeInterval = 600

    static func glucose(at date: Date, in readings: [GlucoseStored]) -> GlucoseStored? {
        let range = date.addingTimeInterval(-window) ... date.addingTimeInterval(window)
        return readings.first { $0.date.map(range.contains) ?? false }
    }

    static func determination(at date: Date, in determinations: [OrefDetermination]) -> OrefDetermination? {
        let range = date.addingTimeInterval(-window) ... date.addingTimeInterval(window)
        let now = Date.now
        return determinations.first {
            $0.deliverAt ?? now >= range.lowerBound && $0.deliverAt ?? now <= range.upperBound
        }
    }

    /// Nearest `ProjectionPoint` to `date` within the lookup window, the same nearest-point
    /// approach `CobIobChart` filters its dashed IOB/COB decay curves with — reused here rather
    /// than reinvented so a scrub and the chart it scrubs always agree on which point answers it.
    private static func nearestProjection(_ points: [ProjectionPoint], to date: Date) -> ProjectionPoint? {
        let range = date.addingTimeInterval(-window) ... date.addingTimeInterval(window)
        return points
            .filter { range.contains($0.date) }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    static func iobProjection(at date: Date, in points: [ProjectionPoint]) -> Double? {
        nearestProjection(points, to: date)?.value
    }

    static func cobProjection(at date: Date, in points: [ProjectionPoint]) -> Double? {
        nearestProjection(points, to: date)?.value
    }

    /// oref writes `minForecast` / `maxForecast` as parallel arrays of 5-minute steps from the
    /// newest determination's `deliverAt` — the same indexing `ForecastView.timeForIndex` uses
    /// to place the forecast cone, so `anchor` must be that same `deliverAt` or the readout and
    /// the cone it is reading off of would disagree about which instant index N is.
    ///
    /// Returns the mg/dL midpoint of the min/max cone at the step nearest `date`; unit
    /// conversion is the caller's job, same as everywhere else oref's raw values reach the UI.
    static func glucoseForecastMidpoint(
        at date: Date,
        minForecast: [Int],
        maxForecast: [Int],
        anchor: Date
    ) -> Decimal? {
        let count = min(minForecast.count, maxForecast.count)
        guard count > 0 else { return nil }

        func indexDate(_ index: Int) -> Date { anchor.addingTimeInterval(TimeInterval(index * 300)) }

        guard let bestIndex = (0 ..< count).min(by: {
            abs(indexDate($0).timeIntervalSince(date)) < abs(indexDate($1).timeIntervalSince(date))
        }), abs(indexDate(bestIndex).timeIntervalSince(date)) <= window else { return nil }

        return Decimal(minForecast[bestIndex] + maxForecast[bestIndex]) / 2
    }
}

/// The selection readout, shown in the Home meal slot in place of IOB / COB / alarms while a
/// scrub is live. A card floating over the glucose pane covered the very data it described;
/// the meal slot is always on screen and its live values are superseded anyway, so taking it
/// over reflows nothing.
///
/// Scrubbing past "now" lands on no `GlucoseStored` and no determination — there is nothing
/// measured yet at that instant. Rather than let the row vanish, `selectedGlucose` is optional
/// and `predictedIOB` / `predictedCOB` / `predictedGlucose` (oref's own projections, already
/// computed for the COB/IOB chart and the forecast cone) fill in for it.
struct ChartSelectionRow: View {
    let selectedGlucose: GlucoseStored?
    /// The scrub timestamp itself. Used for the time label and as the glucose x-position
    /// whenever there is no real reading to hang it off of.
    let selection: Date
    /// COB and IOB both come from the one determination nearest the selection.
    let determination: OrefDetermination?
    let units: GlucoseUnits
    let highGlucose: Decimal
    let lowGlucose: Decimal
    let currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    let isSmoothingEnabled: Bool
    /// oref's projected IOB / COB / glucose at `selection`, already resolved to display units.
    /// Only ever shown when there is no measured value to show instead — a future scrub only.
    let predictedIOB: Decimal?
    let predictedCOB: Decimal?
    let predictedGlucose: Decimal?

    private var glucoseToDisplay: Decimal? {
        guard let selectedGlucose else { return nil }
        return units == .mgdL ? Decimal(selectedGlucose.glucose) : Decimal(selectedGlucose.glucose).asMmolL
    }

    /// mmol/L is written to one decimal even when it is a whole number — 8 reads as 8.0, the
    /// way the rest of the app writes it — and both units go through a formatter so the
    /// decimal separator follows the locale rather than `Decimal.description`'s hard dot.
    private static let glucoseFormatter: (GlucoseUnits) -> NumberFormatter = { units in
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.minimumFractionDigits = units == .mgdL ? 0 : 1
        formatter.maximumFractionDigits = units == .mgdL ? 0 : 1
        return formatter
    }

    private func glucoseString(_ value: Decimal) -> String {
        Self.glucoseFormatter(units).string(from: value as NSDecimalNumber) ?? value.description
    }

    /// nil when there is no measured reading: a predicted glucose has no dynamic-color
    /// verdict to give, so it is never mistaken for the real high/low/in-range coloring.
    private var pointMarkColor: Color? {
        guard let selectedGlucose else { return nil }
        return selectionMarkColor(
            for: selectedGlucose,
            highGlucose: highGlucose,
            lowGlucose: lowGlucose,
            currentGlucoseTarget: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }

    /// The measured reading's own timestamp when there is one — it can sit up to the lookup
    /// window off the raw scrub position — else the scrub position itself.
    private var timeString: String {
        (selectedGlucose?.date ?? selection).formatted(.dateTime.hour().minute(.twoDigits))
    }

    /// Stand-in for a value the selection resolves to nothing: the item keeps its place and
    /// says so rather than vanishing. The spaces are part of the string — the item takes a
    /// `Text` — and keep the dash off its own glyph and off the next item.
    private static let missingValue = Text(verbatim: " \u{2013} ").foregroundStyle(.secondary)

    var body: some View {
        // Nothing may truncate — SwiftUI ellipsised the glucose value — so the whole row
        // steps down a type size until it fits.
        ViewThatFits(in: .horizontal) {
            row(font: .callout)
            row(font: .subheadline)
            row(font: .footnote)
        }
        // Scrubbing changes these several times a second; animating them smears the digits.
        .animation(nil, value: selectedGlucose?.date ?? selection)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        // No reading yet to tint by, so the panel falls back to a neutral tint rather than
        // borrowing a color that would claim a high/low/in-range verdict it can't make.
        .glassPanel(tint: pointMarkColor ?? .secondary, tintOpacity: 0.10, strokeOpacity: 0.25)
    }

    /// Fixed spacing rather than `Spacer`s, so the row hugs its content: with no determination
    /// it shrinks to time and glucose instead of stretching the slot around them. The items
    /// are the plain strings — wide enough apart that a value growing a digit can't run into
    /// its neighbour's glyph, and no reserved width behind them.
    @ViewBuilder private func row(font: Font) -> some View {
        HStack(spacing: 12) {
            item(icon: "clock", tint: .secondary, value: Text(timeString))

            glucoseGroup

            // Three states per item: a real determination (full strength), oref's projection
            // when the scrub is past "now" and no determination will ever cover it (dimmed —
            // see `predictedOpacity`), or neither (the dash).
            let iobUnit = Text(String(localized: " U", comment: "Insulin unit")).fontWeight(.regular)
            let iobString = determination?.iob
                .flatMap { Formatter.decimalFormatterWithTwoFractionDigits.string(from: $0) }
            let predictedIOBString = predictedIOB
                .flatMap { Formatter.decimalFormatterWithTwoFractionDigits.string(from: NSDecimalNumber(decimal: $0)) }
            item(
                icon: "syringe.fill",
                tint: Color.insulin,
                value: iobString.map { Text($0) + iobUnit }
                    ?? predictedIOBString.map { Text($0) + iobUnit }
                    ?? Self.missingValue
            )
            .opacity(predictedOpacity(measured: iobString))

            let cobUnit = Text(String(localized: " g", comment: "gram of carbs")).fontWeight(.regular)
            let cobString = determination
                .flatMap { Formatter.integerFormatter.string(from: $0.cob as NSNumber) }
            let predictedCOBString = predictedCOB
                .flatMap { Formatter.integerFormatter.string(from: NSDecimalNumber(decimal: $0)) }
            item(
                icon: "fork.knife",
                tint: .loopYellow,
                value: cobString.map { Text($0) + cobUnit }
                    ?? predictedCOBString.map { Text($0) + cobUnit }
                    ?? Self.missingValue
            )
            .opacity(predictedOpacity(measured: cobString))
        }
        .font(font).fontWeight(.bold).fontDesign(.rounded)
        // equal-width digits, so a value can't wobble as its digits change mid-scrub
        .monospacedDigit()
        .lineLimit(1)
    }

    /// A measured value renders at full strength; a projection standing in for it — no
    /// determination covers a future scrub — is dimmed to read as oref's estimate rather
    /// than something the sensor reported.
    private func predictedOpacity(measured: String?) -> Double {
        measured == nil ? 0.6 : 1
    }

    /// The reading under the drop and, with smoothing on, the smoothed value in brackets
    /// behind it — marked with the same sparkles glyph the History tab puts on a smoothed
    /// reading. Only the drop and the raw value take the glucose color, so the bracketed
    /// value can't be misread as a second state.
    ///
    /// Past "now" there is no reading at all: oref's forecast (the midpoint of its min/max
    /// cone) stands in, under a trend glyph instead of the drop and in neutral, dimmed text
    /// — a projection, not a color-coded verdict on a real number.
    @ViewBuilder private var glucoseGroup: some View {
        if let selectedGlucose, let glucoseToDisplay, let pointMarkColor {
            // verbatim: brackets have nothing to translate, and Xcode would otherwise extract
            // them into the string catalog
            let reading = Text(glucoseString(glucoseToDisplay)).foregroundStyle(pointMarkColor)
            let smoothed = smoothedToDisplay(for: selectedGlucose).map {
                (
                    Text(verbatim: "(")
                        + Text(Image(systemName: "sparkles"))
                        + Text(verbatim: " ")
                        + Text(glucoseString($0))
                        + Text(verbatim: ")")
                ).foregroundStyle(.secondary)
            }

            item(
                icon: "drop.fill",
                tint: pointMarkColor,
                value: smoothed.map { reading + Text(verbatim: " ") + $0 } ?? reading
            )
        } else if let predictedGlucose {
            item(
                icon: "chart.line.uptrend.xyaxis",
                tint: .secondary,
                value: Text(glucoseString(predictedGlucose)).foregroundStyle(.secondary)
            )
            .opacity(0.6)
        } else {
            item(icon: "drop.fill", tint: .secondary, value: Self.missingValue)
        }
    }

    /// The smoothed reading in display units, or nil with smoothing off or no smoothed value.
    private func smoothedToDisplay(for glucose: GlucoseStored) -> Decimal? {
        guard isSmoothingEnabled, let smoothed = glucose.smoothedGlucose else { return nil }
        return units == .mgdL ? smoothed.decimalValue : smoothed.decimalValue.asMmolL
    }

    /// One value plus its glyph.
    @ViewBuilder private func item(icon: String? = nil, tint: Color = .secondary, value: Text) -> some View {
        HStack(spacing: 4) {
            if let icon {
                // scales with whichever step `ViewThatFits` settled on
                Image(systemName: icon)
                    .imageScale(.small)
                    .foregroundStyle(tint)
            }
            value
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
