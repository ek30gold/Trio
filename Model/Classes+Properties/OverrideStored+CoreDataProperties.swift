import CoreData
import Foundation

public extension OverrideStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<OverrideStored> {
        NSFetchRequest<OverrideStored>(entityName: "OverrideStored")
    }

    @NSManaged var advancedSettings: Bool
    @NSManaged var cr: Bool
    @NSManaged var date: Date?
    @NSManaged var duration: NSDecimalNumber?
    @NSManaged var enabled: Bool
    @NSManaged var end: NSDecimalNumber?
    @NSManaged var id: String?
    @NSManaged var indefinite: Bool
    @NSManaged var isf: Bool
    @NSManaged var isfAndCr: Bool
    @NSManaged var isPreset: Bool
    /// Marks a row created by "Schedule Override" that has not yet been activated.
    /// Distinguishes a pending scheduled Override from a cancelled or finished one — without it,
    /// the two are identical (`enabled == false`, `isPreset == false`, past `date`) and catch-up
    /// would re-activate Overrides the user had cancelled.
    @NSManaged var isScheduled: Bool
    @NSManaged var isUploadedToNS: Bool
    @NSManaged var name: String?
    @NSManaged var orderPosition: Int16
    @NSManaged var percentage: Double
    @NSManaged var smbIsScheduledOff: Bool
    @NSManaged var smbIsOff: Bool
    @NSManaged var smbMinutes: NSDecimalNumber?
    @NSManaged var start: NSDecimalNumber?
    @NSManaged var target: NSDecimalNumber?
    @NSManaged var uamMinutes: NSDecimalNumber?
    @NSManaged var overrideRun: OverrideRunStored?
}

extension OverrideStored: Identifiable {}
