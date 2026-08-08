import Foundation

enum HomeLayoutStyle: String, JSON, CaseIterable, Identifiable, Codable, Hashable {
    var id: String { rawValue }
    case classic
    case modern
    var displayName: String {
        switch self {
        case .classic:
            return String(localized: "Classic", comment: "Home screen layout option")

        case .modern:
            return String(localized: "Modern", comment: "Home screen layout option")
        }
    }
}
