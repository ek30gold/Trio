import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityBasalRateView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var additionalState: LiveActivityAttributes.ContentAdditionalState

    /// Basal rates land on pump-specific increments: 0.05 U/hr on Omnipod and Medtrum, 0.01 U/hr on Dana,
    /// 0.025 U/hr on Medtronic. Three fraction digits is the only setting that renders every one of those
    /// exactly.
    private var basalRateFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 3
        return formatter
    }

    /// The rate to display, or `nil` when it is unknown. Never substitutes 0 for a missing rate -- a
    /// rendered "0" would read as "no insulin is being delivered", a different and much stronger claim
    /// than "we don't know".
    private var formattedBasalRate: String? {
        guard let basalRate = additionalState.basalRate else { return nil }
        return basalRateFormatter.string(from: basalRate as NSNumber)
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                if additionalState.isInsulinSuspended {
                    /// A suspended pump is delivering nothing. Never show a rate here, even when one is
                    /// known -- the payload does not pre-zero the rate, so a number would look like
                    /// active delivery.
                    Text(
                        String(
                            localized: "Suspended",
                            comment: "Live Activity basal value shown while insulin delivery is suspended"
                        )
                    )
                    .fontWeight(.bold)
                    .font(.title3)
                    .foregroundStyle(context.isStale ? .secondary : .primary)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
                } else {
                    Text(formattedBasalRate ?? "--")
                        .fontWeight(.bold)
                        .font(.title3)
                        .foregroundStyle(context.isStale ? .secondary : .primary)
                        .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                    Text(String(localized: "U/hr", comment: "Insulin units per hour abbreviation"))
                        .font(.headline).fontWeight(.bold)
                        .foregroundStyle(context.isStale ? .secondary : .primary)
                        .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
                }
            }
            Text("Basal")
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}
