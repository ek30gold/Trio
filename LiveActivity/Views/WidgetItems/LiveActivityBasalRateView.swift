import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityBasalRateView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var additionalState: LiveActivityAttributes.ContentAdditionalState

    /// Basal rates land on pump-specific increments: 0.05 U/hr on Omnipod and Medtrum, 0.01 U/hr on Dana,
    /// 0.025 U/hr on Medtronic. Three fraction digits is the only setting that renders every one of those
    /// exactly, and it matches the main app's Home view. The five-character case ("0.025") is rare, and
    /// `minimumScaleFactor` below shrinks it to fit rather than letting it truncate — so we buy exactness
    /// in the narrow stat cell without ever printing a rate the pump is not actually delivering.
    private var basalRateFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 3
        return formatter
    }

    /// The rate to display, or nil when it is unknown. Never substitutes 0 — a rendered "0" would read as
    /// "no insulin is being delivered", which is a different and much stronger claim than "we don't know".
    private var formattedBasalRate: String? {
        guard let basalRate = additionalState.basalRate else { return nil }
        return basalRateFormatter.string(from: basalRate as NSNumber)
    }

    /// Emphasis is reserved for a temp basal we can actually name a fresh, known rate for.
    /// Suspended, unknown, and stale all disqualify it: none of those should look like live loop activity.
    private var isTempBasalEmphasized: Bool {
        !additionalState.isInsulinSuspended
            && formattedBasalRate != nil
            && additionalState.isTempBasalActive
            && !context.isStale
    }

    /// Staleness outranks temp-basal emphasis, so a struck-through value can never read as live data.
    private var valueColor: Color {
        if context.isStale { return .secondary }
        return isTempBasalEmphasized ? .blue : .primary
    }

    private var suspendedText: String {
        String(localized: "Suspended", comment: "Live Activity basal label shown when insulin delivery is suspended")
    }

    private var unitText: String {
        String(localized: "U/hr", comment: "Insulin unit per hour abbreviation")
    }

    private var captionText: String {
        String(localized: "Basal", comment: "Live Activity caption beneath the current basal rate")
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                if additionalState.isInsulinSuspended {
                    /// A suspended pump is delivering nothing. Never show a rate here, even when one is
                    /// known — the payload does not pre-zero the rate, so a number would look like delivery.
                    Text(suspendedText)
                        .fontWeight(.bold)
                        .font(.title3)
                        .foregroundStyle(valueColor)
                        .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
                } else if let formattedBasalRate {
                    Text(formattedBasalRate)
                        .fontWeight(isTempBasalEmphasized ? .heavy : .bold)
                        .font(.title3)
                        .foregroundStyle(valueColor)
                        .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                    /// Deliberately smaller than the sibling stat views' `.headline` unit label: those
                    /// render a single "U", this renders four glyphs into the same ~50-60pt cell.
                    Text(unitText)
                        .font(.caption).fontWeight(.bold)
                        .foregroundStyle(valueColor)
                        .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
                } else {
                    /// Rate unknown. Show a placeholder and no unit — attaching "U/hr" to nothing would
                    /// imply we have a reading.
                    Text(verbatim: "--")
                        .fontWeight(.bold)
                        .font(.title3)
                        .foregroundStyle(valueColor)
                        .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            Text(captionText)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}
