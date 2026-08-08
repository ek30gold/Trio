import Foundation
import SwiftUI

// MARK: - Card container

/// The card surface shared by every element of the Modern home layout.
///
/// Uses `Color.chart` for the fill, which already resolves to white in light mode and a dark card
/// colour in dark mode, so the layout follows the user's appearance preference rather than forcing
/// the light palette the design mockups were drawn in.
struct ModernCard<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.chart)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        colorScheme == .dark ? Color.white.opacity(0.08) : Color.clear,
                        lineWidth: 0.5
                    )
            )
            .shadow(
                color: colorScheme == .dark ? Color.clear : Color.black.opacity(0.06),
                radius: 3,
                y: 1
            )
    }
}

// MARK: - Device chip

/// A compact pill showing a single device readout: reservoir, battery or pod age.
struct ModernChip: View {
    let systemImage: String
    let value: String
    var tint: Color = .secondary
    var height: CGFloat = 28

    var body: some View {
        ModernCard(cornerRadius: height / 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .fontDesign(.rounded)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
        }
    }
}

// MARK: - Stat chip

/// A stat tile: small tracked caption above a bold rounded value. Used for IOB, COB and basal.
struct ModernStatChip<Value: View>: View {
    let label: String
    var tint: Color = .secondary
    @ViewBuilder var value: () -> Value

    var body: some View {
        ModernCard(cornerRadius: 14) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .tracking(0.3)
                    // Uppercasing happens here rather than in the source strings so translators
                    // receive normally-cased text and locales that should not uppercase are respected.
                    .textCase(.uppercase)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                value()
                    .font(.callout)
                    .fontWeight(.bold)
                    .fontDesign(.rounded)
                    .lineLimit(1)
                    // Tighten letter spacing before falling back to scaling the glyphs down, so the
                    // longest readout (the basal rate) stays at full size in its share of the row.
                    .allowsTightening(true)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            // Every chip claims the full width offered to it, so an HStack of chips at equal layout
            // priority splits the row evenly. Do not give one chip a higher `layoutPriority`: the
            // stack offers the top-priority child all remaining width first, and because of this
            // modifier it takes every point, collapsing its siblings to an ellipsis.
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Range rail

/// A horizontal bar showing where the current reading sits relative to the user's target range.
///
/// The colour ramp is sampled from `Trio.getDynamicGlucoseColor`, the same function that colours the
/// glucose number itself, so the rail and the number always agree — including under the static colour
/// scheme, where the ramp resolves to discrete red / green / orange bands rather than a gradient.
struct GlucoseRangeRail: View {
    let glucoseValue: Decimal?
    let units: GlucoseUnits
    let lowGlucose: Decimal
    let highGlucose: Decimal
    let currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme

    /// The rail's domain. Matches the hardcoded bounds the dynamic colour scheme already uses at its
    /// call sites in `CurrentGlucoseView` and `GlucoseChartView`, so the ramp spans the full range of
    /// colours those views can produce.
    private let railLowerBound = Decimal(55)
    private let railUpperBound = Decimal(220)

    private let railHeight: CGFloat = 7
    private let thumbDiameter: CGFloat = 14

    /// Colour for an arbitrary glucose value, mirroring `CurrentGlucoseView`'s call exactly —
    /// including its hardcoded 55/220 substitution under the dynamic scheme.
    private func color(for value: Decimal) -> Color {
        let isDynamicColorScheme = glucoseColorScheme == .dynamicColor
        return Trio.getDynamicGlucoseColor(
            glucoseValue: value,
            highGlucoseColorValue: isDynamicColorScheme ? railUpperBound : highGlucose,
            lowGlucoseColorValue: isDynamicColorScheme ? railLowerBound : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }

    /// Position of `value` along the rail as a 0...1 fraction, clamped at both ends so out-of-range
    /// readings park at the edge rather than escaping the bar.
    private func fraction(for value: Decimal) -> CGFloat {
        let span = railUpperBound - railLowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(value, railLowerBound), railUpperBound)
        return CGFloat(Double(truncating: ((clamped - railLowerBound) / span) as NSNumber))
    }

    private var gradient: LinearGradient {
        let sampleCount = 24
        let span = railUpperBound - railLowerBound
        let stops = (0 ... sampleCount).map { step -> Color in
            let value = railLowerBound + (span * Decimal(step) / Decimal(sampleCount))
            return color(for: value)
        }
        return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
    }

    private func axisLabel(_ value: Decimal) -> String {
        units == .mgdL ? value.description : value.formattedAsMmolL
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let usableWidth = max(geo.size.width - thumbDiameter, 0)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(gradient)
                        .frame(height: railHeight)
                        .frame(maxHeight: .infinity, alignment: .center)

                    if let glucoseValue {
                        Circle()
                            .fill(Color.chart)
                            .overlay(
                                Circle()
                                    .stroke(color(for: glucoseValue), lineWidth: 3.5)
                            )
                            .frame(width: thumbDiameter, height: thumbDiameter)
                            .offset(x: fraction(for: glucoseValue) * usableWidth)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
            }
            .frame(height: thumbDiameter)

            HStack {
                Text(axisLabel(railLowerBound))
                Spacer()
                Text(axisLabel(lowGlucose))
                Spacer()
                Text(axisLabel(highGlucose))
                Spacer()
                Text(axisLabel(railUpperBound))
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Trend direction

extension BloodGlucose.Direction {
    /// Rotation applied to the Modern layout's trend arrow. Mirrors the mapping
    /// `CurrentGlucoseView` uses for the Classic layout's triangle.
    var modernTrendRotation: Double {
        switch self {
        case .doubleUp,
             .singleUp,
             .tripleUp:
            return -90
        case .fortyFiveUp:
            return -45
        case .flat:
            return 0
        case .fortyFiveDown:
            return 45
        case .doubleDown,
             .singleDown,
             .tripleDown:
            return 90
        case .notComputable,
             .rateOutOfRange:
            return 0
        default:
            return 0
        }
    }
}
