import CoreData
import Foundation
import SwiftUI

/// Lets the user rename, edit, delete, and manually reorder their saved meal presets.
/// Reached either from `MealPresetView`'s "Manage" button (passing the already-active,
/// already-configured `Treatments.StateModel` from the live Treatments flow), or from
/// Settings > Features > Treatments > Manage Meal Presets (`Screen.manageMealPresets`,
/// which builds and configures a standalone `Treatments.StateModel` for this screen alone --
/// see `Screen.swift`).
struct ManageMealPresetsView: View {
    @Bindable var state: Treatments.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @Environment(\.managedObjectContext) var moc
    @Environment(AppState.self) var appState

    @State private var showAddNewPresetSheet = false
    @State private var editingPreset: MealPresetStored?

    @State private var dish: String = ""
    @State private var note: String = ""
    @State private var presetCarbs: Decimal = 0
    @State private var presetFat: Decimal = 0
    @State private var presetProtein: Decimal = 0

    private var mealFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(state.mealPresets, id: \.self) { preset in
                    Button {
                        populateEditForm(from: preset)
                        editingPreset = preset
                    } label: {
                        presetRow(for: preset)
                    }
                }
                .onMove(perform: state.reorderMealPreset)
                .onDelete(perform: deletePresets)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Manage Meal Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        EditButton()
                        Button(action: { showAddNewPresetSheet = true }) {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddNewPresetSheet) {
                AddMealPresetView(
                    dish: $dish,
                    note: $note,
                    presetCarbs: $presetCarbs,
                    presetFat: $presetFat,
                    presetProtein: $presetProtein,
                    displayFatAndProtein: $state.useFPUconversion,
                    onSave: saveNewPreset,
                    onCancel: {
                        showAddNewPresetSheet = false
                        resetForm()
                    }
                )
            }
            .sheet(item: $editingPreset) { preset in
                AddMealPresetView(
                    dish: $dish,
                    note: $note,
                    presetCarbs: $presetCarbs,
                    presetFat: $presetFat,
                    presetProtein: $presetProtein,
                    displayFatAndProtein: $state.useFPUconversion,
                    onSave: { saveEdit(to: preset) },
                    onCancel: {
                        editingPreset = nil
                        resetForm()
                    }
                )
            }
        }
        .onAppear {
            state.setupMealPresetsArray()
        }
    }

    @ViewBuilder private func presetRow(for preset: MealPresetStored) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preset.dish ?? "")
                .foregroundStyle(.primary)
            if let note = preset.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                macroLabel("Carbs: ", value: decimalValue(preset.carbs))
                if state.useFPUconversion {
                    macroLabel("Fat: ", value: decimalValue(preset.fat))
                    macroLabel("Protein: ", value: decimalValue(preset.protein))
                }
            }
        }
    }

    @ViewBuilder private func macroLabel(_ label: LocalizedStringKey, value: Decimal) -> some View {
        HStack(spacing: 0) {
            Text(label)
            HStack(spacing: 2) {
                Text("\(value as NSNumber, formatter: mealFormatter)")
                Text(" g")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func decimalValue(_ number: NSDecimalNumber?) -> Decimal {
        ((number ?? 0) as NSDecimalNumber) as Decimal
    }

    private func populateEditForm(from preset: MealPresetStored) {
        dish = preset.dish ?? ""
        note = preset.note ?? ""
        presetCarbs = decimalValue(preset.carbs)
        presetFat = decimalValue(preset.fat)
        presetProtein = decimalValue(preset.protein)
    }

    private func resetForm() {
        dish = ""
        note = ""
        presetCarbs = 0
        presetFat = 0
        presetProtein = 0
    }

    private func saveNewPreset() {
        guard !dish.isEmpty else { return }
        let preset = MealPresetStored(context: moc)
        preset.dish = dish
        preset.note = note.isEmpty ? nil : note
        preset.orderPosition = Int16(state.mealPresets.count + 1)
        preset.carbs = presetCarbs as NSDecimalNumber
        if state.useFPUconversion {
            preset.fat = presetFat as NSDecimalNumber
            preset.protein = presetProtein as NSDecimalNumber
        }
        do {
            guard moc.hasChanges else { return }
            try moc.save()
            state.setupMealPresetsArray()
            showAddNewPresetSheet = false
            resetForm()
        } catch let error as NSError {
            debugPrint("\(DebuggingIdentifiers.failed) Failed to save Meal Preset with error: \(error.userInfo)")
        }
    }

    private func saveEdit(to preset: MealPresetStored) {
        guard !dish.isEmpty else { return }
        preset.dish = dish
        preset.note = note.isEmpty ? nil : note
        preset.carbs = presetCarbs as NSDecimalNumber
        if state.useFPUconversion {
            preset.fat = presetFat as NSDecimalNumber
            preset.protein = presetProtein as NSDecimalNumber
        } else {
            preset.fat = nil
            preset.protein = nil
        }
        do {
            guard moc.hasChanges else { return }
            try moc.save()
            state.setupMealPresetsArray()
            editingPreset = nil
            resetForm()
        } catch let error as NSError {
            debugPrint("\(DebuggingIdentifiers.failed) Failed to update Meal Preset with error: \(error.userInfo)")
        }
    }

    private func deletePresets(at offsets: IndexSet) {
        for index in offsets {
            let preset = state.mealPresets[index]
            moc.delete(preset)
        }
        do {
            guard moc.hasChanges else { return }
            try moc.save()
            state.setupMealPresetsArray()
        } catch let error as NSError {
            debugPrint("\(DebuggingIdentifiers.failed) Failed to delete Meal Preset with error: \(error.userInfo)")
        }
    }
}
