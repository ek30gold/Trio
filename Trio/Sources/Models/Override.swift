import Foundation

struct Override {
    let name: String
    let enabled: Bool
    let date: Date
    let duration: Decimal
    let indefinite: Bool
    let percentage: Double
    let smbIsOff: Bool
    let isPreset: Bool
    let id: String
    let overrideTarget: Bool
    let target: Decimal
    let advancedSettings: Bool
    let isfAndCr: Bool
    let isf: Bool
    let cr: Bool
    let smbIsScheduledOff: Bool
    let start: Decimal
    let end: Decimal
    let smbMinutes: Decimal
    let uamMinutes: Decimal
    /// True only for an Override created by "Schedule Override" that has not started yet.
    /// Cleared once the Override is activated, so a finished or cancelled Override is never
    /// mistaken for one still waiting to start.
    var isScheduled: Bool = false
}
