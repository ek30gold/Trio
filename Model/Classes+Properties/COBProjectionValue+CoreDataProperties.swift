import CoreData
import Foundation

public extension COBProjectionValue {
    @nonobjc class func fetchRequest() -> NSFetchRequest<COBProjectionValue> {
        NSFetchRequest<COBProjectionValue>(entityName: "COBProjectionValue")
    }

    @NSManaged var index: Int32
    @NSManaged var value: NSDecimalNumber?
    @NSManaged var cobProjection: COBProjection?
}

extension COBProjectionValue: Identifiable {}
