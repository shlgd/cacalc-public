import SwiftUI

struct PreparedFoodView: View {
    @Environment(DiaryStore.self) private var store
    @State private var stocks: [BatchStock] = []
    @State private var recipes: [RecipeTemplate] = []
    @State private var savedDrafts: [CookingState] = []
    @State private var readIssues: [StoredDataIssue] = []
    @State private var editing: CookingState?
    @State private var dishMode = 0
    private var recipeMode: Bool { dishMode == 1 }
    @State private var showingHistory = false
    @State private var choosingRecipe = false
    @State private var queuedCooking: CookingState?
    @State private var stockToDiscard: BatchStock?
    @State private var error: String?
    private var repository: PreparedRepository { PreparedRepository(container: store.container) }
    private var active: [BatchStock] { stocks.filter(\.active) }
    private func reload() {
        do {
            let snapshot = try repository.stockSnapshot(); stocks = snapshot.stocks; readIssues = snapshot.issues
            recipes = try repository.recipes(); readIssues += repository.readIssues
            let saved = try repository.drafts(); savedDrafts = saved.values; readIssues += saved.issues
        }
        catch { self.error = error.localizedDescription }
    }
    private func open(_ state: CookingState) {
        do {
            let existing = state.templateOnly == true ? savedDrafts.first { $0.templateOnly == true && $0.recipe.id == state.recipe.id } : nil
            let selected = existing ?? state
            try repository.saveDraft(selected)
            editing = selected
        } catch { self.error = error.localizedDescription }
    }
    private func start() {
        if recipeMode { open(CookingState(templateOnly: true)) }
        else if recipes.isEmpty { open(CookingState()) }
        else { choosingRecipe = true }
    }
    var body: some View {
        NavigationStack {
            navigableList
            .sheet(item: $editing, onDismiss: reload) { CookingEditorView(initial: $0) }
            .sheet(isPresented: $choosingRecipe, onDismiss: {
                if let next = queuedCooking { queuedCooking = nil; open(next) }
            }) {
                recipeChooser
            }
            .alert("Не удалось выполнить действие", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Понятно") { UsageTelemetry.shared.action("PreparedFoodView.button.114"); error = nil }
            } message: { Text(error ?? "") }
        }
        .modifier(BatchDiscardConfirmation(stock: $stockToDiscard, completed: reload))
    }
    private var navigableList: some View {
            dishList
            .listStyle(.insetGrouped)
            .navigationTitle("Блюда")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("История приготовлений", systemImage: "clock.arrow.circlepath") { UsageTelemetry.shared.action("PreparedFoodView.button.82"); showingHistory = true }
                    } label: { Image(systemName: "ellipsis") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if dishMode != 2 { Button(recipeMode ? "Новый рецепт" : "Приготовить", systemImage: "plus", action: usageAction("PreparedFoodView.button.86", start)) }
                }
            }
            .navigationDestination(isPresented: $showingHistory) {
                List(stocks.filter { !$0.active }) { stock in
                    NavigationLink { detail(stock) } label: { PreparedStockLabel(stock: stock) }
                }.usageScroll("PreparedFoodView.scroll.48")
                .overlay { if stocks.allSatisfy(\.active) { ContentUnavailableView("История пока пуста", systemImage: "clock") } }
                .navigationTitle("История")
            }
            .usagePresentation("cookingHistory", visible: showingHistory)
            .usagePresentation("recipeChooser", visible: choosingRecipe)
            .onAppear(perform: reload)
            .onChange(of: dishMode) { _, value in UsageTelemetry.shared.event("dishesModeChanged", ["mode": String(value)]) }
            .onChange(of: showingHistory) { _, value in UsageTelemetry.shared.event("historyPresentation", ["visible": String(value)]) }
            .onChange(of: choosingRecipe) { _, value in UsageTelemetry.shared.event("recipeChooserPresentation", ["visible": String(value)]) }
    }
    private var dishList: some View {
            List {
                Section {
                    ForEach(savedDrafts.filter { dishMode != 2 && ($0.templateOnly == true) == recipeMode }) { savedDraft in
                        Button { UsageTelemetry.shared.action("PreparedFoodView.button.37"); open(savedDraft) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(savedDraft.recipe.name.isEmpty ? "Продолжить" : savedDraft.recipe.name)
                                    Text(savedDraft.templateOnly == true ? "Редактируете рецепт" : "Готовите · продолжить")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "pencil.line") }
                        }.tint(.primary)
                    }
                }
                if !readIssues.isEmpty { Section { ForEach(readIssues) { Text($0.message).font(.footnote).foregroundStyle(.orange) } } }
                if dishMode == 2 {
                    CombinationList(mode: $dishMode)
                } else {
                Section {
                    if recipeMode {
                        if recipes.isEmpty { empty }
                        ForEach(recipes) { recipe in
                            NavigationLink {
                                RecipeDetailView(recipe: recipe, edit: {
                                    open(CookingState(templateOnly: true, recipe: recipe))
                                }, cook: { open(CookingState(recipe: recipe)) })
                            } label: { RecipeSummary(recipe: recipe) }
                        }
                    } else {
                        if active.isEmpty { empty }
                        ForEach(active) { stock in
                            NavigationLink { detail(stock) } label: { PreparedStockLabel(stock: stock) }
                                .swipeActions(allowsFullSwipe: false) {
                                    DiscardBatchButton(stock: stock, selection: $stockToDiscard)
                                    Button("Закончилось", systemImage: "checkmark") { UsageTelemetry.shared.action("PreparedFoodView.button.63");
                                        do { try repository.close(stock.batch); reload() }
                                        catch { self.error = error.localizedDescription }
                                    }.tint(.orange)
                                }
                        }
                    }
                } header: {
                    Picker("Блюда", selection: $dishMode) {
                        Text("Приготовлено").tag(0)
                        Text("Рецепты").tag(1)
                        Text("Сочетания").tag(2)
                    }.pickerStyle(.segmented).textCase(nil).padding(.bottom, 12)
                }
                }
            }.usageScroll("PreparedFoodView.scroll.70")
    }
    private var recipeChooser: some View {
                NavigationStack {
                    List {
                        Button("Новое блюдо", systemImage: "plus") { UsageTelemetry.shared.action("PreparedFoodView.button.103"); queuedCooking = CookingState(); choosingRecipe = false }
                        Section("По рецепту") {
                            ForEach(recipes) { recipe in
                                Button { UsageTelemetry.shared.action("PreparedFoodView.button.106"); queuedCooking = CookingState(recipe: recipe); choosingRecipe = false } label: { RecipeSummary(recipe: recipe) }.tint(.primary)
                            }
                        }
                    }.usageScroll("PreparedFoodView.scroll.116").navigationTitle("Приготовить")
                        .toolbar { Button("Закрыть") { UsageTelemetry.shared.action("PreparedFoodView.button.110"); choosingRecipe = false } }
                }.presentationDetents([.medium, .large])
    }
    private var empty: some View {
        ContentUnavailableView {
            Label(recipeMode ? "Ваши рецепты" : "Пока ничего не приготовлено", systemImage: recipeMode ? "book" : "fork.knife")
        } description: {
            Text(recipeMode ? "Сохраните состав, чтобы в следующий раз готовить быстрее." : "Добавьте блюдо — здесь появятся его вес и оставшиеся порции.")
        } actions: {
            Button(recipeMode ? "Создать рецепт" : "Приготовить блюдо", action: usageAction("PreparedFoodView.button.124", start)).buttonStyle(.borderedProminent)
        }.listRowBackground(Color.clear)
    }
    private func detail(_ stock: BatchStock) -> some View {
        BatchDetailView(stock: stock, repeatBatch: {
            var recipe = stock.batch.recipe
            recipe.ingredients = recipe.ingredients.map { var value = $0; value.planned = value.actual; return value }
            open(CookingState(recipe: recipe))
        })
    }
}
private struct RecipeSummary: View {
    let recipe: RecipeTemplate
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(recipe.name).font(.headline)
            Text(recipe.ingredients.prefix(3).map { $0.product.name }.joined(separator: ", ") + (recipe.ingredients.count > 3 ? "…" : ""))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }.padding(.vertical, 4)
    }
}
private struct PreparedStockLabel: View {
    let stock: BatchStock
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stock.batch.name).font(.headline)
                PreparedAgeLabel(batch: stock.batch)
            }
            if stock.active {
                Text("≈\(Numbers.display(stock.grams)) г осталось").font(.title3).monospacedDigit()
                PortionSegments(total: max(stock.batch.portions, stock.portions), remaining: stock.portions)
                if let next = stock.nextGrams {
                    Text("Следующая порция ≈\(Numbers.display(next)) г").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(stock.batch.discard.map { "Выброшено · " + $0.reason.title.lowercased() } ?? "Закончилось")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
    }
}
private struct PreparedAgeLabel: View {
    let batch: PreparedBatch
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(batch.ageLabel(at: context.date)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DiscardBatchButton: View {
    let stock: BatchStock
    @Binding var selection: BatchStock?
    var body: some View {
        Button("Выбросить", systemImage: "trash") {
            UsageTelemetry.shared.action("Prepared.discard.request")
            UsageTelemetry.shared.event("preparedBatchDiscardRequested", ["batchID": stock.id.uuidString])
            selection = stock
        }.tint(.red)
    }
}

/// The screen owns confirmation; swipe controls disappear as soon as their action runs.
private struct BatchDiscardConfirmation: ViewModifier {
    @Environment(DiaryStore.self) private var store
    @State private var error: String?
    @Binding var stock: BatchStock?
    let completed: () -> Void
    private var confirming: Binding<Bool> {
        Binding(get: { stock != nil }, set: { if !$0 { stock = nil } })
    }
    func body(content: Content) -> some View {
        content
        .confirmationDialog("Выбросить «\(stock?.batch.name ?? "блюдо")»?", isPresented: confirming,
                            titleVisibility: .visible, presenting: stock) { selected in
            Button("Испортилось", role: .destructive) {
                UsageTelemetry.shared.action("Prepared.discard.spoiled"); discard(selected, reason: .spoiled)
            }
            Button("Выбросил по другой причине", role: .destructive) {
                UsageTelemetry.shared.action("Prepared.discard.other"); discard(selected, reason: .other)
            }
            Button("Отмена", role: .cancel) { UsageTelemetry.shared.action("Prepared.discard.cancel") }
        } message: { _ in
            Text("Оставшаяся еда исчезнет из доступных блюд. Приготовление, причина и количество останутся в истории. В съеденное ничего не добавится.")
        }
        .alert("Не удалось списать блюдо", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Понятно") { UsageTelemetry.shared.action("Prepared.discard.errorDismiss"); error = nil }
        } message: { Text(error ?? "") }
        .usagePresentation("discardPreparedBatch", visible: stock != nil)
    }
    private func discard(_ stock: BatchStock, reason: BatchDiscard.Reason) {
        do {
            let changed = try PreparedRepository(container: store.container).discard(stock.id, reason: reason)
            UsageTelemetry.shared.event("preparedBatchDiscardResult", ["batchID": stock.id.uuidString,
                "reason": reason.rawValue, "result": changed ? "saved" : "alreadyDiscarded"])
            completed()
        } catch {
            self.error = error.localizedDescription
            UsageTelemetry.shared.event("preparedBatchDiscardFailed", ["batchID": stock.id.uuidString, "reason": reason.rawValue])
        }
    }
}
private struct PortionSegments: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let total: Decimal
    let remaining: Decimal
    private var count: Int { max(1, Int(ceil(NSDecimalNumber(decimal: total).doubleValue))) }
    var body: some View {
        GeometryReader { geometry in
            let width = max(14, (geometry.size.width - CGFloat(count - 1) * 6) / CGFloat(count))
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(0..<count, id: \.self) { index in
                        let fill = min(1, max(0, NSDecimalNumber(decimal: remaining).doubleValue - Double(index)))
                        Capsule().fill(Color.primary.opacity(0.10))
                            .overlay(alignment: .leading) { Capsule().fill(.green).frame(width: width * fill) }
                            .frame(width: width, height: 7)
                    }
                }
            }.usageScroll("PreparedFoodView.scroll.177").scrollIndicators(.hidden)
        }.frame(height: 7)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: remaining)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Осталось \(Numbers.display(remaining)) из \(Numbers.display(total)) порций")
    }
}
private struct RecipeDetailView: View {
    let recipe: RecipeTemplate
    let edit: () -> Void
    let cook: () -> Void
    var body: some View {
        UsageScreen("RecipeDetailView") {
        List {
            Section("Ингредиенты") {
                ForEach(recipe.ingredients) { ingredient in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ingredient.product.name)
                            if !ingredient.product.brand.isEmpty { Text(ingredient.product.brand).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(ingredient.planned + (ingredient.product.basis == .ml ? " мл" : " г")).monospacedDigit()
                    }
                }
            }
            if let note = recipe.note, !note.isEmpty {
                Section("Заметка") { Text(note).textSelection(.enabled) }
            }
        }.usageScroll("PreparedFoodView.scroll.199").navigationTitle(recipe.name)
            .toolbar { Button("Изменить", action: usageAction("PreparedFoodView.button.206", edit)) }
            .safeAreaInset(edge: .bottom) {
                Button("Приготовить", action: usageAction("PreparedFoodView.button.208", cook)).buttonStyle(.glassProminent).controlSize(.large)
                    .padding(.bottom, 12)
            }
            }
}
}

private struct BatchDetailView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var correcting = false
    @State private var stockToDiscard: BatchStock?
    @State private var grams = ""
    @State private var portions = ""
    @State private var error: String?
    let stock: BatchStock
    let repeatBatch: () -> Void
    var body: some View {
        UsageScreen("BatchDetailView") {
        List {
            Section("Приготовление") {
                PreparedAgeLabel(batch: stock.batch)
                LabeledContent("Приготовлено", value: stock.batch.created.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Выход", value: "\(Numbers.display(stock.batch.yieldGrams)) г")
                PortionSegments(total: max(stock.batch.portions, stock.portions), remaining: stock.active ? stock.portions : 0)
                LabeledContent("Осталось", value: stock.active ? "≈\(Numbers.display(stock.grams)) г" : (stock.batch.discard == nil ? "Закончилось" : "Выброшено"))
                if !stock.active && stock.batch.discard == nil && stock.grams > 0 {
                    Text("Расчётный остаток \(Numbers.display(stock.grams)) г не записан как съеденный.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let discard = stock.batch.discard {
                Section("Списание") {
                    LabeledContent("Причина", value: discard.reason.title)
                    LabeledContent("Когда", value: discard.date.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Выброшено", value: "\(Numbers.display(discard.grams)) г")
                    Text("Это не съеденная еда. Прежние записи дневника сохранены.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("На 100 г") { NutritionText(value: stock.batch.product) }
            Section("Ингредиенты · план / факт") {
                ForEach(stock.batch.recipe.ingredients) { value in
                    LabeledContent(value.product.name, value: "\(value.planned.isEmpty ? "—" : value.planned) / \(value.actual) \(value.product.basis.rawValue == "ml" ? "мл" : "г")")
                }
            }
            if let note = stock.batch.recipe.note, !note.isEmpty {
                Section("Заметка") { Text(note).textSelection(.enabled) }
            }
            if stock.batch.discard == nil {
            Button("Поправить остаток") { UsageTelemetry.shared.action("PreparedFoodView.button.242");
                grams = Numbers.string(stock.grams); portions = Numbers.string(stock.portions); correcting = true
            }
            }
            if stock.active { DiscardBatchButton(stock: stock, selection: $stockToDiscard) }
            Button("Повторить это приготовление", action: usageAction("PreparedFoodView.button.245", repeatBatch))
        }.usageScroll("PreparedFoodView.scroll.236").navigationTitle(stock.batch.name)
        .modifier(BatchDiscardConfirmation(stock: $stockToDiscard, completed: { dismiss() }))
        .usagePresentation("stockCorrection", visible: correcting)
        .sheet(isPresented: $correcting) {
            NavigationStack {
                Form {
                    TextField("Осталось граммов", text: $grams).keyboardType(.decimalPad)
                    TextField("Осталось порций", text: $portions).keyboardType(.decimalPad)
                    Text("Это корректировка остатка. Калории записанной еды не изменятся.").font(.caption)
                    if let error { Text(error).foregroundStyle(.orange) }
                }.usageScroll("PreparedFoodView.scroll.261")
                .navigationTitle("Остаток")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { UsageTelemetry.shared.action("PreparedFoodView.button.257"); correcting = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") { UsageTelemetry.shared.action("PreparedFoodView.button.259");
                            do {
                                try PreparedRepository(container: store.container).adjust(stock.id,
                                    grams: Numbers.parse(grams), portions: Numbers.parse(portions))
                                correcting = false; dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }.presentationDetents([.medium])
        }
            }
}
}
private struct NutritionText: View {
    let snapshot: PortionSnapshot
    init(value: Product) { snapshot = PortionSnapshot(calories: value.calories, protein: value.protein, fat: value.fat, carbs: value.carbs) }
    init(snapshot: PortionSnapshot) { self.snapshot = snapshot }
    private func n(_ value: Decimal?) -> String { value.map { Numbers.display($0) } ?? "—" }
    var body: some View {
        Text("\(n(snapshot.calories)) ккал · Б \(n(snapshot.protein)) · Ж \(n(snapshot.fat)) · У \(n(snapshot.carbs))")
            .font(.subheadline).foregroundStyle(.secondary)
    }
}
struct CookingEditorView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var state: CookingState
    @State private var writer: DraftWriter<CookingState>?
    @State private var saving = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = false
    @State private var finishing = false
    @State private var replacingIngredient: UUID?
    @State private var unitNotice: String?
    @State private var error: String?
    @State private var finished = false
    @State private var originalRecipe: RecipeTemplate?
    @State private var namingNewDish = false
    @State private var confirmDiscard = false
    init(initial: CookingState) { _state = State(initialValue: initial) }
    private var repository: PreparedRepository { PreparedRepository(container: store.container) }
    private var templateOnly: Bool { state.templateOnly == true }
    private var ingredientsTotal: PortionSnapshot? {
        try? PreparedBatch.make(recipe: state.recipe, yieldGrams: 100, portions: 1).total
    }
    private var preview: PreparedBatch? {
        guard let weight = try? Numbers.parse(state.yieldText, positive: true),
              let count = try? Numbers.parse(state.portionText, positive: true) else { return nil }
        return try? PreparedBatch.make(recipe: state.recipe, yieldGrams: weight, portions: count)
    }
    private var recipeChanged: Bool {
        guard let originalRecipe else { return false }
        if originalRecipe.ingredients.count != state.recipe.ingredients.count { return true }
        return zip(originalRecipe.ingredients, state.recipe.ingredients).contains {
            $0.product.id != $1.product.id || (try? Numbers.parse($0.planned)) != (try? Numbers.parse($1.actual))
        }
    }
    var body: some View {
        UsageScreen("CookingEditorView") {
        NavigationStack {
            Form {
                if templateOnly || namingNewDish {
                    Section { TextField("Название блюда", text: $state.recipe.name).font(.title3) }
                } else if !state.recipe.name.isEmpty {
                    Section { Text(state.recipe.name).font(.title3.weight(.semibold)) }
                }
                Section {
                    ForEach($state.recipe.ingredients) { $ingredient in
                        HStack(alignment: .center, spacing: 12) {
                            Button { UsageTelemetry.shared.action("PreparedFoodView.button.324"); chooseReplacement(ingredient.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ingredient.product.name)
                                if !ingredient.product.brand.isEmpty { Text(ingredient.product.brand).font(.caption).foregroundStyle(.secondary) }
                                if !templateOnly && !ingredient.planned.isEmpty {
                                    Text("План " + ingredient.planned + (ingredient.product.basis == .ml ? " мл" : " г"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            }.buttonStyle(.plain)
                            Spacer(minLength: 0)
                            TextField("—", text: $ingredient.actual).keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing).font(.title3).monospacedDigit()
                                .frame(width: 86, height: 44)
                                .accessibilityLabel("Количество: " + ingredient.product.name)
                            Text(ingredient.product.basis == .ml ? "мл" : "г").foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Удалить", systemImage: "trash", role: .destructive) { UsageTelemetry.shared.action("PreparedFoodView.button.342");
                                state.recipe.ingredients.removeAll { $0.id == ingredient.id }
                            }.tint(.red)
                            Button("Заменить", systemImage: "arrow.triangle.2.circlepath") { UsageTelemetry.shared.action("PreparedFoodView.button.345"); chooseReplacement(ingredient.id) }.tint(.blue)
                        }
                    }
                    .onMove { offsets, destination in
                        UsageTelemetry.shared.event("ingredientsReordered", ["from": offsets.map(String.init).joined(separator: ","), "to": String(destination)])
                        state.recipe.ingredients.move(fromOffsets: offsets, toOffset: destination)
                    }
                    Button("Добавить ингредиент", systemImage: "plus") { UsageTelemetry.shared.action("PreparedFoodView.button.351"); replacingIngredient = nil; search = true }
                    if let unitNotice { Text(unitNotice).font(.caption).foregroundStyle(.secondary) }
                } header: { Text("Ингредиенты") } footer: {
                    Text(templateOnly ? "Эти количества станут планом. При приготовлении их можно изменить." : "Укажите фактически добавленные количества. Воду можно пропустить.")
                }
                if templateOnly {
                    Section("Заметка") {
                        TextField("Как готовить, что учесть…", text: Binding(get: { state.recipe.note ?? "" }, set: { state.recipe.note = $0.isEmpty ? nil : $0 }), axis: .vertical)
                            .lineLimit(3...12)
                    }
                } else if let note = state.recipe.note, !note.isEmpty {
                    Section("Заметка рецепта") { Text(note).textSelection(.enabled) }
                }
                if let total = ingredientsTotal {
                    Section("Всего в ингредиентах") { NutritionText(snapshot: total) }
                }
            }.usageScroll("PreparedFoodView.scroll.329")
            .disabled(saving || finished)
            .scrollDismissesKeyboard(.immediately)
            .scrollBounceBehavior(.always)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
            .navigationTitle(templateOnly ? "Рецепт" : "Приготовление")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { UsageTelemetry.shared.action("PreparedFoodView.button.378"); closeEditor() }.disabled(saving) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { Button("Удалить заготовку", role: .destructive) { UsageTelemetry.shared.action("PreparedFoodView.button.380"); confirmDiscard = true } } label: { Image(systemName: "ellipsis") }.disabled(saving)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(templateOnly ? "Сохранить рецепт" : "Блюдо готово") { UsageTelemetry.shared.action("PreparedFoodView.button.384");
                    if templateOnly { save(recipe: true) } else { finishing = true }
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(ingredientsTotal == nil || finished || saving).padding(.bottom, 12)
            }
            .usagePresentation("cookingFinish", visible: finishing)
            .navigationDestination(isPresented: $finishing) { finishView }
            .sheet(isPresented: $search) {
                IngredientPicker { product in
                    guard !saving, !finished else { return }
                    do {
                        if let id = replacingIngredient {
                            let changedUnit = try state.recipe.replaceIngredient(id, with: product)
                            unitNotice = changedUnit ? "У нового продукта другая единица. Укажите количество заново." : nil
                        } else { state.recipe.ingredients.append(RecipeIngredient(product: product)) }
                    } catch { self.error = error.localizedDescription }
                    replacingIngredient = nil
                }
            }
            .onAppear {
                if writer == nil {
                    let persistence = WorkDraftRepository(container: store.container)
                    writer = DraftWriter(write: { try await persistence.persist($0) }, failed: { self.error = $0.localizedDescription })
                    writer?.submit(state, id: state.id)
                }
                do {
                    originalRecipe = try repository.recipes().first { $0.id == state.recipe.id }
                    namingNewDish = originalRecipe == nil
                }
                catch { self.error = error.localizedDescription }
            }
            .onChange(of: state) { _, _ in if !finished { writer?.submit(state, id: state.id) } }
            .onChange(of: scenePhase) { _, phase in if phase == .background { Task { do { try await flushDraft() } catch { self.error = error.localizedDescription } } } }
            .onDisappear { if !finished { Task { do { try await flushDraft() } catch { self.error = error.localizedDescription } } } }
            .confirmationDialog("Удалить эту заготовку?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { UsageTelemetry.shared.action("PreparedFoodView.button.412");
                    Task {
                        do { try await flushDraft(); try repository.discardDraft(state.id); finished = true; dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .alert("Не удалось сохранить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Понятно") { UsageTelemetry.shared.action("PreparedFoodView.button.418"); error = nil }
            } message: { Text(error ?? "") }
        }
            }
}
    private var finishView: some View {
        Form {
            Section {
                HStack {
                    Text("Итоговый вес")
                    Spacer()
                    TextField("—", text: $state.yieldText).keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing).font(.title2).monospacedDigit().frame(minWidth: 80, maxWidth: 150)
                    Text("г").foregroundStyle(.secondary)
                }
            } footer: { Text("Взвесьте готовое блюдо без посуды.") }
            Section("Разделить на порции") {
                HStack {
                    ForEach([2,3,4,5], id: \.self) { count in
                        Button("\(count)") { UsageTelemetry.shared.action("PreparedFoodView.button.436"); state.portionText = String(count) }
                            .frame(maxWidth: .infinity).buttonStyle(.bordered)
                            .tint(state.portionText == String(count) ? .green : .secondary)
                    }
                }
                HStack {
                    Text("Количество")
                    Spacer()
                    TextField("—", text: $state.portionText).keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing).frame(width: 90)
                }
                if let preview {
                    PortionSegments(total: preview.portions, remaining: preview.portions).padding(.vertical, 5)
                    Text("≈\(Numbers.display(preview.yieldGrams / preview.portions)) г на порцию").font(.title3).monospacedDigit()
                    NutritionText(snapshot: PortionSnapshot(
                        calories: preview.total.calories.map { $0 / preview.portions },
                        protein: preview.total.protein.map { $0 / preview.portions },
                        fat: preview.total.fat.map { $0 / preview.portions },
                        carbs: preview.total.carbs.map { $0 / preview.portions }))
                    Text("В дневник записывайте фактически взвешенные граммы.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if recipeChanged {
                Section {
                    Toggle("Обновить рецепт", isOn: $state.updateTemplate)
                } footer: { Text("Сохранить сегодняшний состав и количества как план для следующего приготовления.") }
            }
        }.usageScroll("PreparedFoodView.scroll.439")
        .disabled(saving || finished)
        .scrollDismissesKeyboard(.immediately)
            .scrollBounceBehavior(.always)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        .navigationTitle("Блюдо готово").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button("Сохранить приготовление") { UsageTelemetry.shared.action("PreparedFoodView.button.473"); save(recipe: false) }
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(preview == nil || finished || saving).padding(.bottom, 12)
        }
    }
    private func chooseReplacement(_ id: UUID) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        replacingIngredient = id; search = true
    }
    private func save(recipe: Bool) {
        guard !finished, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await flushDraft()
                if recipe { try repository.saveRecipe(state) } else { try repository.create(state) }
                finished = true; dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func flushDraft() async throws {
        guard !finished else { return }
        if let writer { writer.submit(state, id: state.id); try await writer.flush() }
        else { try repository.saveDraft(state) }
    }
    private func closeEditor() {
        Task { do { try await flushDraft(); dismiss() } catch { self.error = error.localizedDescription } }
    }

}

struct IngredientPicker: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Product] = []
    @State private var error: String?
    let selected: (Product) -> Void
    var body: some View {
        UsageScreen("IngredientPicker") {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.orange) }
                ForEach(results) { product in
                    Button { UsageTelemetry.shared.action("PreparedFoodView.button.508");
                        selected(product); dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(product.name)
                            if !product.brand.isEmpty { Text(product.brand).font(.caption).foregroundStyle(.secondary) }
                            NutritionText(value: product)
                        }
                    }.tint(.primary)
                }
            }.usageScroll("PreparedFoodView.scroll.522")
            .navigationTitle("Ингредиент")
            .searchable(text: $query, prompt: "Найти продукт")
            .toolbar { Button("Закрыть") { UsageTelemetry.shared.action("PreparedFoodView.button.521"); dismiss() } }
            .task(id: query) {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                    let found = try await store.rankedSearch(query)
                    guard !Task.isCancelled else { return }
                    results = found.filter { $0.preparedBatchID == nil && ($0.basis == .g || $0.basis == .ml) }
                    error = nil
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
        }
            }
}
}
