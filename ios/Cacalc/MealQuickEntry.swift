import SwiftUI

/// Nutrition for this entry, never a catalog product or a per-100-g value.
struct MealQuickEntry: View {
    @Environment(\.dismiss) private var dismiss
    let row: MealRow
    let save: (MealRow) async throws -> Void
    @State private var name: String
    @State private var calories: String
    @State private var protein: String
    @State private var fat: String
    @State private var carbs: String
    @State private var saving = false
    @State private var error: String?

    init(row: MealRow, save: @escaping (MealRow) async throws -> Void) {
        self.row = row; self.save = save
        _name = State(initialValue: row.food)
        let nutrition = row.manualNutrition
        _calories = State(initialValue: nutrition?.calories.map(Numbers.string) ?? "")
        _protein = State(initialValue: nutrition?.protein.map(Numbers.string) ?? "")
        _fat = State(initialValue: nutrition?.fat.map(Numbers.string) ?? "")
        _carbs = State(initialValue: nutrition?.carbs.map(Numbers.string) ?? "")
    }
    private func value() throws -> MealRow {
        var value = row
        value.food = name
        value.manualNutrition = try PortionSnapshot(calories: Numbers.parse(calories),
            protein: Numbers.parse(protein), fat: Numbers.parse(fat), carbs: Numbers.parse(carbs))
        return try value.validated()
    }
    var body: some View {
        UsageScreen("MealQuickEntry") {
        NavigationStack {
            Form {
                Section { TextField("Название", text: $name) }
                Section {
                    field("Калории, ккал", text: $calories)
                    field("Белки, г", text: $protein)
                    field("Жиры, г", text: $fat)
                    field("Углеводы, г", text: $carbs)
                } header: { Text("За всё добавляемое количество") }
                footer: { Text("Только для этого приёма пищи. В каталог не добавляется.") }
                if let error { Text(error).foregroundStyle(.red) }
            }.usageScroll("MealQuickEntry.scroll.35")
            .disabled(saving)
            .navigationTitle("Быстрый ввод")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { UsageTelemetry.shared.action("MealQuickEntry.button.49"); dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(row.manualNutrition == nil ? "Добавить" : "Сохранить") { UsageTelemetry.shared.action("MealQuickEntry.button.51");
                        saving = true
                        Task { @MainActor in
                            do { try await save(value()); dismiss() }
                            catch { self.error = error.localizedDescription; saving = false }
                        }
                    }.disabled(saving || (try? value()) == nil)
                }
            }
        }
        .interactiveDismissDisabled(saving)
            }
}
    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            TextField("0", text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
    }
}
