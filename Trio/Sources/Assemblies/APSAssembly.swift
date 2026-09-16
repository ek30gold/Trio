import Foundation
import Swinject

final class APSAssembly: Assembly {
    func assemble(container: Container) {
        container.register(DeviceDataManager.self) { r in BaseDeviceDataManager(resolver: r) }
        container.register(APSManager.self) { r in BaseAPSManager(resolver: r) }
        container.register(FetchGlucoseManager.self) { r in BaseFetchGlucoseManager(resolver: r) }
        container.register(FetchTreatmentsManager.self) { r in BaseFetchTreatmentsManager(resolver: r) }
        container.register(BluetoothStateManager.self) { r in BaseBluetoothStateManager(resolver: r) }
        container.register(PluginManager.self) { r in BasePluginManager(resolver: r) }
        container.register(CalibrationService.self) { r in BaseCalibrationService(resolver: r) }
        // Lives here rather than in ServiceAssembly (where AdjustmentManager is registered)
        // because it is driven by FetchGlucoseManager's timer, also in this assembly, and reads
        // exclusively from the APS-layer Override/TempTarget storage — it delegates the actual
        // activation transaction to AdjustmentManager rather than owning one itself.
        container.register(ScheduledOverrideManager.self) { r in BaseScheduledOverrideManager(resolver: r) }
            .inObjectScope(.container)
    }
}
