import CoreData
import Foundation

public extension IOBProjection {
    @nonobjc class func fetchRequest() -> NSFetchRequest<IOBProjection> {
        NSFetchRequest<IOBProjection>(entityName: "IOBProjection")
    }

    @NSManaged var date: Date?
    @NSManaged var id: UUID?
    @NSManaged var iobProjectionValues: Set<IOBProjectionValue>?
    @NSManaged var orefDetermination: OrefDetermination?
}

// MARK: Generated accessors for iobProjectionValues

public extension IOBProjection {
    @objc(addIobProjectionValuesObject:)
    @NSManaged func addToIobProjectionValues(_ value: IOBProjectionValue)

    @objc(removeIobProjectionValuesObject:)
    @NSManaged func removeFromIobProjectionValues(_ value: IOBProjectionValue)

    @objc(addIobProjectionValues:)
    @NSManaged func addToIobProjectionValues(_ values: NSSet)

    @objc(removeIobProjectionValues:)
    @NSManaged func removeFromIobProjectionValues(_ values: NSSet)
}

extension IOBProjection: Identifiable {}
