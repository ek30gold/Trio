import CoreData
import Foundation

public extension IOBProjectionValue {
    @nonobjc class func fetchRequest() -> NSFetchRequest<IOBProjectionValue> {
        NSFetchRequest<IOBProjectionValue>(entityName: "IOBProjectionValue")
    }

    @NSManaged var index: Int32
    @NSManaged var value: NSDecimalNumber?
    @NSManaged var iobProjection: IOBProjection?
}

extension IOBProjectionValue: Identifiable {}
