import Foundation

extension TrioRemoteControl {
    /// Handles a remote meal command.
    ///
    /// - Returns: `true` if the meal was logged, `false` if it was rejected. The caller must not
    /// deliver an attached bolus for a rejected meal — previously every rejection path returned
    /// normally, so a meal refused for exceeding its limits still delivered its full meal bolus
    /// with no carbs on board.
    @discardableResult
    func handleMealCommand(_ payload: CommandPayload) async throws -> Bool {
        guard payload.carbs != nil || payload.fat != nil || payload.protein != nil else {
            await logError("Command rejected: meal data is incomplete or invalid.", payload: payload)
            return false
        }

        let carbsDecimal = payload.carbs != nil ? Decimal(payload.carbs!) : nil
        let fatDecimal = payload.fat != nil ? Decimal(payload.fat!) : nil
        let proteinDecimal = payload.protein != nil ? Decimal(payload.protein!) : nil

        let settings = await TrioApp.resolver.resolve(SettingsManager.self)?.settings
        let maxCarbs = settings?.maxCarbs ?? Decimal(0)
        let maxFat = settings?.maxFat ?? Decimal(0)
        let maxProtein = settings?.maxProtein ?? Decimal(0)

        if let carbs = carbsDecimal, carbs > maxCarbs {
            await logError(
                "Command rejected: carbs amount (\(carbs)g) exceeds the maximum allowed (\(maxCarbs)g).",
                payload: payload
            )
            return false
        }
        if let fat = fatDecimal, fat > maxFat {
            await logError("Command rejected: fat amount (\(fat)g) exceeds the maximum allowed (\(maxFat)g).", payload: payload)
            return false
        }
        if let protein = proteinDecimal, protein > maxProtein {
            await logError(
                "Command rejected: protein amount (\(protein)g) exceeds the maximum allowed (\(maxProtein)g).",
                payload: payload
            )
            return false
        }

        let payloadDate = Date(timeIntervalSince1970: payload.timestamp)
        let taskContext = CoreDataStack.shared.newTaskContext()
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: CarbEntryStored.self, onContext: taskContext, predicate: NSPredicate(
                format: "date > %@",
                payloadDate as NSDate
            ), key: "date", ascending: false
        )

        // Reject a replayed or duplicated command. The rejection used to be logged from inside a
        // detached `Task`, whose `return` exited only that closure — so the command was logged as
        // rejected and then stored anyway, doubling the carbs.
        let hasNewerCarbEntries = await taskContext.perform {
            guard let recentCarbEntries = results as? [CarbEntryStored] else { return false }
            return !recentCarbEntries.isEmpty
        }

        if hasNewerCarbEntries {
            await logError(
                "Command rejected: newer carb entries have been logged since the command was sent.",
                payload: payload
            )
            return false
        }

        let actualDate = payload.scheduledTime.map { Date(timeIntervalSince1970: $0) }

        let mealEntry = CarbsEntry(
            id: UUID().uuidString, createdAt: Date(), actualDate: actualDate,
            carbs: carbsDecimal ?? 0, fat: fatDecimal, protein: proteinDecimal,
            note: "Remote meal command", enteredBy: CarbsEntry.local, isFPU: false,
            fpuID: fatDecimal ?? 0 > 0 || proteinDecimal ?? 0 > 0 ? UUID().uuidString : nil
        )

        try await carbsStorage.storeCarbs([mealEntry], areFetchedFromRemote: false)

        if payload.bolusAmount == nil {
            await logSuccess(
                "Remote command processed successfully. \(payload.humanReadableDescription())",
                payload: payload,
                customNotificationMessage: "Meal logged"
            )
        }

        return true
    }
}
