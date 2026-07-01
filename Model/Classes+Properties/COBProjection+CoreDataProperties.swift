import CoreData
import Foundation

public extension COBProjection {
    @nonobjc class func fetchRequest() -> NSFetchRequest<COBProjection> {
        NSFetchRequest<COBProjection>(entityName: "COBProjection")
    }

    @NSManaged var date: Date?
    @NSManaged var id: UUID?
    @NSManaged var cobProjectionValues: Set<COBProjectionValue>?
    @NSManaged var orefDetermination: OrefDetermination?
}

// MARK: Generated accessors for cobProjectionValues

public extension COBProjection {
    @objc(addCobProjectionValuesObject:)
    @NSManaged func addToCobProjectionValues(_ value: COBProjectionValue)

    @objc(removeCobProjectionValuesObject:)
    @NSManaged func removeFromCobProjectionValues(_ value: COBProjectionValue)

    @objc(addCobProjectionValues:)
    @NSManaged func addToCobProjectionValues(_ values: NSSet)

    @objc(removeCobProjectionValues:)
    @NSManaged func removeFromCobProjectionValues(_ values: NSSet)
}

extension COBProjection: Identifiable {}
