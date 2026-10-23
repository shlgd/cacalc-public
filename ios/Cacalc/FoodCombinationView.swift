import SwiftUI

struct CombinationList: View {
    @Environment(DiaryStore.self) private var store
    @State private var values: [FoodCombination] = []
    @State private var editing: CombinationDraft?
    @State private var drafts: [CombinationDraft] = []
    @State private var readIssues: [StoredDataIssue] = []
    @State private var error: String?
    var onUse: (() -> Void)? = nil
    var mode: Binding<Int>? = nil
    private func reload() {
        do {
            let repo = CombinationRepository(container: store.container)
            values = try repo.all()
            let saved = try repo.drafts(); drafts = saved.values; readIssues = repo.readIssues + saved.issues
        }
        catch { self.error = error.localizedDescription }
    }
    var body: some View {
        Section {
            ForEach(readIssues) { Text($0.message).font(.footnote).foregroundStyle(.orange) }
            ForEach(drafts) { draft in
                Button {
                    UsageTelemetry.shared.action("Combination.resumeDraft"); editing = draft
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.value.name.isEmpty ? "Новое сочетание" : draft.value.name)
                        Text("Продолжить · " + (draft.value.components.isEmpty ? "Пустой состав" : draft.value.components.map(\.name).joined(separator: " · ")))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.tint(.primary)
            }
            if values.isEmpty {
                ContentUnavailableView("Ваши сочетания", systemImage: "square.stack.3d.up",
                    description: Text("Сохраните продукты и блюда, которые любите есть вместе."))
            }
            ForEach(values) { value in
                NavigationLink {
                    CombinationDetail(initial: value, onUse: onUse)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(value.name)
                        Text(value.components.map(\.name).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .swipeActions {
                    Button("Удалить", systemImage: "trash", role: .destructive) {
                        UsageTelemetry.shared.action("Combination.delete")
                        do { try CombinationRepository(container: store.container).delete(value); reload() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            Button("Новое сочетание", systemImage: "plus") {
                UsageTelemetry.shared.action("Combination.create")
                do { editing = try CombinationRepository(container: store.container).begin(FoodCombination()) }
                catch { self.error = error.localizedDescription }
            }
        } header: {
            if let mode {
                Picker("Блюда", selection: mode) {
                    Text("Приготовлено").tag(0)
                    Text("Рецепты").tag(1)
                    Text("Сочетания").tag(2)
                }.pickerStyle(.segmented).textCase(nil).padding(.bottom, 12)
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $editing, onDismiss: reload) { CombinationEditor(draft: $0) }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Понятно") { UsageTelemetry.shared.action("Combination.listError"); error = nil }
        } message: { Text(error ?? "") }
    }
}

struct CombinationEditor: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var value: FoodCombination
    @State private var draft: CombinationDraft?
    @State private var writer: DraftWriter<CombinationDraft>?
    @State private var finished = false
    @State private var saving = false
    @State private var confirmDiscard = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = false
    @State private var recipes: [RecipeTemplate] = []
    @State private var error: String?
    @State private var replacing: UUID?
    init(initial: FoodCombination) { _value = State(initialValue: initial) }
    init(draft: CombinationDraft) { _value = State(initialValue: draft.value); _draft = State(initialValue: draft) }
    private func snapshot() -> CombinationDraft? { guard var draft else { return nil }; draft.value = value; return draft }
    private func flush() async throws {
        if let state = snapshot(), let writer { writer.submit(state, id: state.id); try await writer.flush() }
    }
    private func close() {
        guard !saving else { return }; saving = true
        Task { defer { saving = false }; do { try await flush(); dismiss() } catch { self.error = error.localizedDescription } }
    }

    private func select(_ source: CombinationComponent.Source) {
        guard !saving, !finished else { return }
        if let replacing, let index = value.components.firstIndex(where: { $0.id == replacing }) {
            let oldUnit = value.components[index].unit
            value.components[index].source = source
            if value.components[index].unit != oldUnit { value.components[index].quantity = "" }
        } else { value.components.append(CombinationComponent(source: source)) }
        replacing = nil
    }
    var body: some View {
        UsageScreen("CombinationEditor") {
            NavigationStack {
                Form {
                    Section {
                        TextField("Название сочетания", text: $value.name)
                        TextField("Заметка", text: $value.note, axis: .vertical)
                    }
                    Section {
                        ForEach($value.components) { $component in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(component.name)
                                        if case .product(let product) = component.source, !product.brand.isEmpty {
                                            Text(product.brand).font(.caption).foregroundStyle(.secondary)
                                        }
                                        if component.recipeID != nil { Text("По рецепту").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer(minLength: 12)
                                    TextField("—", text: $component.quantity).keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing).frame(width: 76)
                                        .accessibilityLabel("Количество: " + component.name)
                                    Text(component.unit.title).foregroundStyle(.secondary)
                                }
                                if component.recipeID != nil {
                                    HStack {
                                        Text("Списать порций").font(.subheadline).foregroundStyle(.secondary)
                                        Spacer()
                                        TextField("1", text: $component.portions).keyboardType(.decimalPad)
                                            .multilineTextAlignment(.trailing).frame(width: 76)
                                            .accessibilityLabel("Число порций: " + component.name)
                                    }
                                }
                            }
                            .swipeActions {
                                Button("Удалить", systemImage: "trash", role: .destructive) {
                                    UsageTelemetry.shared.action("Combination.removeComponent")
                                    value.components.removeAll { $0.id == component.id }
                                }
                            }
                            .contextMenu {
                                Button("Заменить продукт") {
                                    UsageTelemetry.shared.action("Combination.replaceProduct"); replacing = component.id; search = true
                                }
                                Menu("Заменить блюдом") {
                                    ForEach(recipes) { recipe in
                                        Button(recipe.name) {
                                            UsageTelemetry.shared.action("Combination.replaceRecipe")
                                            replacing = component.id; select(.recipe(id: recipe.id, name: recipe.name))
                                        }
                                    }
                                }
                            }
                        }
                        .onMove { offsets, index in value.components.move(fromOffsets: offsets, toOffset: index) }
                        Button("Добавить продукт", systemImage: "plus") {
                            UsageTelemetry.shared.action("Combination.addProduct"); replacing = nil; search = true
                        }
                        Menu {
                            ForEach(recipes) { recipe in
                                Button(recipe.name) {
                                    UsageTelemetry.shared.action("Combination.addRecipe"); replacing = nil
                                    select(.recipe(id: recipe.id, name: recipe.name))
                                }
                            }
                        } label: { Label("Добавить блюдо по рецепту", systemImage: "book") }
                        .disabled(recipes.isEmpty)
                    } header: { Text("Состав") } footer: {
                        Text("Граммы и порции независимы. Конкретную приготовленную партию выберете при добавлении в приём. Для замены удерживайте строку.")
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                }
                .disabled(saving || finished)
                .scrollDismissesKeyboard(.immediately)
                .navigationTitle("Сочетание").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть") { UsageTelemetry.shared.action("Combination.cancelEdit"); close() }.disabled(saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") {
                            UsageTelemetry.shared.action("Combination.save")
                            guard !saving else { return }; saving = true
                            Task {
                                defer { saving = false }
                                do { try await flush(); guard let state = snapshot() else { return }
                                    try CombinationRepository(container: store.container).save(state); finished = true; dismiss() }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled((try? value.validate()) == nil || saving)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu { Button("Удалить черновик", role: .destructive) {
                            UsageTelemetry.shared.action("Combination.discardDraft")
                            confirmDiscard = true
                        } } label: { Image(systemName: "ellipsis") }.disabled(saving)
                    }
                }
                .sheet(isPresented: $search) { IngredientPicker { select(.product($0)) } }
                .task {
                    do {
                        if draft == nil { draft = try CombinationRepository(container: store.container).begin(value); value = draft!.value }
                        let persistence = WorkDraftRepository(container: store.container)
                        writer = DraftWriter(write: { try await persistence.persist($0) }, failed: { self.error = $0.localizedDescription })
                        recipes = try PreparedRepository(container: store.container).recipes()
                    } catch { self.error = error.localizedDescription }
                }
                .onChange(of: value) { _, _ in if !finished, let state = snapshot() { writer?.submit(state, id: state.id) } }
                .onChange(of: scenePhase) { _, phase in if phase == .background { Task { do { try await flush() } catch { self.error = error.localizedDescription } } } }
                .onDisappear { if !finished { Task { do { try await flush() } catch { self.error = error.localizedDescription } } } }
                .interactiveDismissDisabled()
                .confirmationDialog("Удалить этот черновик?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Удалить", role: .destructive) {
                        UsageTelemetry.shared.action("Combination.confirmDiscardDraft")
                        guard !saving else { return }; saving = true
                        Task { defer { saving = false }
                            do { try await flush(); if let draft { try CombinationRepository(container: store.container).discardDraft(draft.id) }; finished = true; dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
        }
    }
}

struct CombinationDetail: View {
    @Environment(DiaryStore.self) private var store
    @Environment(MealSession.self) private var meal
    @State private var value: FoodCombination
    @State private var editing = false
    @State private var using = false
    @State private var preparedRows: [MealRow]?
    @State private var owner: UUID?
    @State private var error: String?
    let onUse: (() -> Void)?
    init(initial: FoodCombination, onUse: (() -> Void)? = nil) {
        _value = State(initialValue: initial); self.onUse = onUse
    }
    var body: some View {
        UsageScreen("CombinationDetail") {
            List {
                Section {
                    ForEach(value.components) { component in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(component.name)
                                if component.recipeID != nil {
                                    Text("По рецепту · \(component.portions) порц.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(component.quantity + " " + component.unit.title)
                        }
                    }
                }
                if !value.note.isEmpty { Section("Заметка") { Text(value.note) } }
                Section {
                    Button("Добавить в приём", systemImage: "plus") {
                        UsageTelemetry.shared.action("Combination.use")
                        owner = meal.draft?.id; using = true
                    }.disabled(meal.saving || meal.busy || meal.draft?.editingEntryID != nil)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(value.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Изменить") { UsageTelemetry.shared.action("Combination.edit"); editing = true }
            }
            .sheet(isPresented: $editing, onDismiss: {
                do {
                    if let updated = try CombinationRepository(container: store.container).all().first(where: { $0.id == value.id }) { value = updated }
                } catch { self.error = error.localizedDescription }
            }) { CombinationEditor(initial: value) }
            .sheet(isPresented: $using, onDismiss: {
                guard let rows = preparedRows else { return }
                preparedRows = nil
                Task {
                    do {
                        try await meal.addCombination(rows, combinationID: value.id, owner: owner)
                        onUse?()
                    } catch { self.error = error.localizedDescription }
                }
            }) {
                CombinationUse(initial: value) { preparedRows = $0 }
            }
        }
    }
}

private struct CombinationUse: View {
    @Environment(DiaryStore.self) private var store
    @Environment(MealSession.self) private var meal
    @Environment(\.dismiss) private var dismiss
    @State private var value: FoodCombination
    @State private var stocks: [BatchStock] = []
    @State private var selections: [UUID: UUID] = [:]
    @State private var error: String?
    @State private var finished = false
    let selected: ([MealRow]) -> Void
    init(initial: FoodCombination, selected: @escaping ([MealRow]) -> Void) {
        _value = State(initialValue: initial); self.selected = selected
    }
    private var preview: [MealRow]? { try? value.rows(stocks: stocks, selections: selections) }
    var body: some View {
        UsageScreen("CombinationUse") {
            NavigationStack {
                Form {
                    Section {
                        Text(meal.draft.map { $0.meal.title + " · " + $0.day.title(relativeTo: store.today) } ?? store.selectedDay.title(relativeTo: store.today))
                            .foregroundStyle(.secondary)
                    }
                    ForEach($value.components) { $component in
                        Section(component.name) {
                            if component.recipeID != nil {
                                let choices = component.candidates(stocks)
                                if choices.isEmpty {
                                    Text("Нет приготовленной партии. Приготовьте блюдо во вкладке «Блюда» или замените компонент в сочетании.")
                                        .foregroundStyle(.orange)
                                } else {
                                    Picker("Партия", selection: Binding<UUID?>(get: {
                                        selections[component.id] ?? (choices.count == 1 ? choices[0].id : nil)
                                    }, set: { selections[component.id] = $0 })) {
                                        Text("Выберите партию").tag(nil as UUID?)
                                        ForEach(choices) { stock in
                                            Text(stock.batch.created.formatted(date: .abbreviated, time: .shortened) + " · " + Numbers.display(stock.grams) + " г")
                                                .tag(Optional(stock.id))
                                        }
                                    }
                                }
                                HStack {
                                    Text("Списать порций")
                                    TextField("1", text: $component.portions).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                }
                            }
                            HStack {
                                Text(component.unit == .g ? "Граммы" : "Миллилитры")
                                TextField("—", text: $component.quantity).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            }
                            if let row = try? component.row(stocks: stocks, selectedBatch: selections[component.id]) {
                                CombinationNutrition(snapshot: row.portion)
                            }
                        }
                    }
                    if let preview {
                        Section("Всего") {
                            let sum = NutritionSummary(preview.map(\.portion))
                            CombinationNutrition(snapshot: PortionSnapshot(
                                calories: sum.missingCalories == 0 ? sum.known.calories : nil,
                                protein: sum.missingProtein == 0 ? sum.known.protein : nil,
                                fat: sum.missingFat == 0 ? sum.known.fat : nil,
                                carbs: sum.missingCarbs == 0 ? sum.known.carbs : nil))
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                .scrollDismissesKeyboard(.immediately)
                .navigationTitle("Добавить сочетание").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отмена") { UsageTelemetry.shared.action("Combination.cancelUse"); dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Добавить") {
                            UsageTelemetry.shared.action("Combination.confirmUse")
                            guard !finished else { return }
                            do {
                                let fresh = try PreparedRepository(container: store.container).stocks()
                                let rows = try value.rows(stocks: fresh, selections: selections)
                                finished = true; selected(rows); dismiss()
                            } catch { self.error = error.localizedDescription }
                        }.disabled(preview == nil || finished)
                    }
                }
                .task {
                    do {
                        stocks = try PreparedRepository(container: store.container).stocks()
                        for component in value.components {
                            let choices = component.candidates(stocks)
                            if choices.count == 1 { selections[component.id] = choices[0].id }
                        }
                    }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}
private struct CombinationNutrition: View {
    let snapshot: PortionSnapshot
    private func n(_ value: Decimal?) -> String { value.map { Numbers.display($0) } ?? "—" }
    var body: some View {
        Text("\(n(snapshot.calories)) ккал · Б \(n(snapshot.protein)) · Ж \(n(snapshot.fat)) · У \(n(snapshot.carbs))")
            .font(.caption).foregroundStyle(.secondary)
    }
}
