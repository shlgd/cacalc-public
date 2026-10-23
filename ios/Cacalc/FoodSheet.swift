import SwiftUI

struct FoodSheet: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var results: [Product] = []
    @State private var searching = false
    @State private var scannerOpen = false
    @State private var discardAlert = false
    @State private var deleteAlert = false
    @State private var queryError: String?
    private func field(_ key: WritableKeyPath<FoodDraft, String>) -> Binding<String> {
        Binding(get: { store.draft?[keyPath: key] ?? "" }, set: { value in store.editDraft { $0[keyPath: key] = value } })
    }
    private var basis: Binding<Basis> {
        Binding(get: { store.draft?.basis ?? .unknown }, set: { value in store.editDraft { $0.basis = value } })
    }
    var body: some View {
        UsageScreen("FoodSheet") {
        NavigationStack {
            Group {
                if let d = store.draft {
                    if d.custom { customForm(d) }
                    else if let product = d.product { portionForm(d, product: product) }
                    else { searchForm(d) }
                } else { ContentUnavailableView("Черновик закрыт", systemImage: "checkmark.circle") }
            }
            .navigationTitle(store.draft?.editingID == nil ? "Добавить еду" : "Изменить запись")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { UsageTelemetry.shared.action("FoodSheet.button.32"); UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                        .accessibilityIdentifier("dismissKeyboard")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { UsageTelemetry.shared.action("FoodSheet.button.36"); dismiss() }.accessibilityIdentifier("closeFood")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Удалить черновик", role: .destructive) { UsageTelemetry.shared.action("FoodSheet.button.40"); discardAlert = true }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Действия с черновиком")
                }
            }
            .alert("Ошибка", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("Понятно", role: .cancel) { UsageTelemetry.shared.action("FoodSheet.button.45"); store.error = nil }
            } message: { Text(store.error ?? "") }
            .confirmationDialog("Удалить черновик?", isPresented: $discardAlert, titleVisibility: .visible) {
                Button("Удалить черновик", role: .destructive) { UsageTelemetry.shared.action("FoodSheet.button.48"); store.perform { try store.persistDraft(nil); dismiss() } }
            }
            .confirmationDialog("Удалить запись из дневника?", isPresented: $deleteAlert, titleVisibility: .visible) {
                Button("Удалить запись", role: .destructive) { UsageTelemetry.shared.action("FoodSheet.button.51");
                    if let id = store.draft?.editingID { store.perform { try store.remove(id) } }
                }
            }
            .sheet(isPresented: $scannerOpen) {
                ScannerSheet { code in
                    scannerOpen = false
                    store.editDraft { $0.query = code; $0.product = nil }
                }
            }
        }
            }
}
    private func searchForm(_ d: FoodDraft) -> some View {
        List {
            Section {
                Text("\(d.meal.title) · \(d.day.date.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "ru_RU"))))")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Название или штрихкод", text: field(\.query)).autocorrectionDisabled()
                        .accessibilityIdentifier("productSearch")
                }
                Button { UsageTelemetry.shared.action("FoodSheet.button.73"); scannerOpen = true } label: { Label("Сканировать штрихкод", systemImage: "barcode.viewfinder") }
                    .accessibilityIdentifier("scanBarcode")
            }
            if let problem = queryError ?? store.catalogError {
                Section { Text(problem).foregroundStyle(.secondary) }
            }
            Section {
                if searching { ProgressView("Ищем в локальном каталоге") }
                else if d.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Введите название продукта или отсканируйте упаковку.").foregroundStyle(.secondary)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: d.query)
                }
                ForEach(results) { product in
                    Button { UsageTelemetry.shared.action("FoodSheet.button.87"); store.choose(product) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(product.name).foregroundStyle(.primary)
                            if !product.displayDetail.isEmpty { Text(product.displayDetail).font(.caption).foregroundStyle(.secondary) }
                            if let kcal = product.calories {
                                Text("\(Numbers.display(kcal, places: 0)) ккал / 100 \(product.basis == .unknown ? "г или мл" : product.basis.title)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if product.nutrition == nil { Text("Нужно дополнить КБЖУ").font(.caption).foregroundStyle(.orange) }
                        }
                    }.accessibilityIdentifier("product_\(product.id)")
                }
            }
            Section {
                Button { UsageTelemetry.shared.action("FoodSheet.button.101"); store.customProduct() } label: { Label("Создать свой продукт", systemImage: "plus.circle") }
                    .accessibilityIdentifier("createProduct")
            }
        }.usageScroll("FoodSheet.scroll.66")
        .task(id: d.query) {
            results = []; queryError = nil
            guard !d.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searching = false; return }
            searching = true
            do {
                try await Task.sleep(for: .milliseconds(180))
                let found = try await store.rankedSearch(d.query)
                try Task.checkCancellation()
                results = found; searching = false
            } catch is CancellationError { }
            catch { queryError = error.localizedDescription; searching = false }
        }
    }
    private func portionForm(_ d: FoodDraft, product: Product) -> some View {
        Form {
            Section {
                Text(product.name).font(.headline)
                if !product.displayDetail.isEmpty { Text(product.displayDetail).font(.subheadline).foregroundStyle(.secondary) }
                if d.editingID == nil {
                    Button("Выбрать другой продукт") { UsageTelemetry.shared.action("FoodSheet.button.124"); store.editDraft { $0.product = nil; $0.quantity = ""; $0.basis = .unknown } }
                }
            }
            Section("Порция") {
                if product.basis == .unknown { basisPicker }
                HStack {
                    TextField("Количество", text: field(\.quantity)).keyboardType(.decimalPad).accessibilityIdentifier("quantity")
                    Text(d.basis.title).foregroundStyle(.secondary)
                }
                if let amount = try? Numbers.parse(d.quantity, positive: true) {
                    var confirmed = product
                    let _ = confirmed.basis = d.basis
                    if let total = try? confirmed.portion(amount, unit: d.basis) {
                        nutritionRow("В порции", total.calories, suffix: "ккал")
                        Text("Б \(Numbers.display(total.protein)) · Ж \(Numbers.display(total.fat)) · У \(Numbers.display(total.carbs)) г")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if product.nutrition == nil {
                    Text("В карточке не хватает КБЖУ. Дополните данные по упаковке.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Дополнить КБЖУ") { UsageTelemetry.shared.action("FoodSheet.button.144"); store.customProduct() }
                }
            }
            Section {
                DisclosureGroup("КБЖУ и данные продукта") {
                    nutritionRow("Калории", product.calories, suffix: "ккал")
                    nutritionRow("Белки", product.protein)
                    nutritionRow("Жиры", product.fat)
                    nutritionRow("Углеводы", product.carbs)
                    LabeledContent("Значения на", value: "100 \(d.basis.title)")
                    if let barcode = product.barcode { Text(barcode).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if product.issues.contains("source:") {
                        Text("Источник отмечает ошибки данных. Сверьте карточку с упаковкой.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Исправить по упаковке") { UsageTelemetry.shared.action("FoodSheet.button.158"); store.customProduct() }
                }
                if d.editingID != nil { Button("Удалить запись", role: .destructive) { UsageTelemetry.shared.action("FoodSheet.button.160"); deleteAlert = true } }
            } footer: {
                Text(product.source == "user-label" ? "Данные с вашей упаковки. Сохраняются только на этом устройстве." : "Источник: Open Food Facts, ODbL. Запись сохранит копию этих значений.")
            }
        }.usageScroll("FoodSheet.scroll.121")
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button(d.day > store.today ? "Запланировать" : "Сохранить запись") { UsageTelemetry.shared.action("FoodSheet.button.167"); store.perform { try store.commitDraft() } }
                .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 8)
                .buttonStyle(.glassProminent).padding(.horizontal, 20).padding(.vertical, 10)
                .accessibilityIdentifier("saveEntry")
        }
    }
    private var basisPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("На упаковке значения указаны:").font(.subheadline)
            Picker("Основа пищевой ценности", selection: basis) {
                Text("Выбрать").tag(Basis.unknown)
                Text("На 100 г").tag(Basis.g)
                Text("На 100 мл").tag(Basis.ml)
            }.pickerStyle(.segmented).accessibilityIdentifier("basisPicker")
            Text("Запомним для следующих записей. Граммы и миллилитры не пересчитываются друг в друга.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func customForm(_ d: FoodDraft) -> some View {
        Form {
            Section("Продукт") {
                TextField("Название", text: field(\.customName)).accessibilityIdentifier("customName")
                TextField("Штрихкод, необязательно", text: field(\.customBarcode)).keyboardType(.numberPad)
            }
            Section("Данные с упаковки") {
                basisPicker
                numberField("Калории, ккал", \.customCalories, id: "customCalories")
                numberField("Белки, г", \.customProtein, id: "customProtein")
                numberField("Жиры, г", \.customFat, id: "customFat")
                numberField("Углеводы, г", \.customCarbs, id: "customCarbs")
            }
            Section {
                Button("Далее — количество") { UsageTelemetry.shared.action("FoodSheet.button.199"); store.perform { try store.finishCustom() } }
                    .accessibilityIdentifier("customContinue")
            } footer: { Text("Карточка сохранится вместе с записью. Калории берём с упаковки, а не вычисляем из БЖУ.") }
        }.usageScroll("FoodSheet.scroll.188")
    }
    private func numberField(_ title: String, _ path: WritableKeyPath<FoodDraft, String>, id: String) -> some View {
        HStack {
            Text(title)
            TextField("0", text: field(path)).keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityIdentifier(id)
        }
    }
    private func nutritionRow(_ title: String, _ value: Decimal?, suffix: String = "г") -> some View {
        LabeledContent(title, value: value.map { "\(Numbers.display($0)) \(suffix)" } ?? "Нет данных")
    }
}
