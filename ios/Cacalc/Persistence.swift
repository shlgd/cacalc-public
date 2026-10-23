import Foundation
import SQLite3
import SwiftData
import Observation
#if os(iOS)
import WidgetKit
#endif

enum PersonalSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Record.self, PersonalProduct.self, DraftRecord.self, GoalRecord.self] }
    @Model final class Record {
        @Attribute(.unique) var id: UUID
        var dayKey: String
        var mealKey: String
        var productData: Data
        var amount: String
        var unit: String
        init(id: UUID, day: Day, meal: Meal, productData: Data, amount: String, unit: Basis) {
            self.id = id; dayKey = day.rawValue; mealKey = meal.rawValue
            self.productData = productData; self.amount = amount; self.unit = unit.rawValue
        }
    }
    @Model final class PersonalProduct {
        @Attribute(.unique) var key: String
        var name: String
        var barcode: String?
        var data: Data
        init(_ product: Product, data: Data) {
            key = product.id; name = product.name; barcode = product.barcode; self.data = data
        }
    }
    @Model final class DraftRecord {
        @Attribute(.unique) var key: String
        var data: Data
        init(_ data: Data) { key = "current"; self.data = data }
    }
    @Model final class GoalRecord {
        @Attribute(.unique) var effectiveDay: String
        var data: Data
        init(day: String, data: Data) { effectiveDay = day; self.data = data }
    }
}

enum PersonalSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        PersonalSchema.models + [ProductDraftRecord.self]
    }
    @Model final class ProductDraftRecord {
        @Attribute(.unique) var key: String
        var data: Data
        init(_ data: Data) { key = "current"; self.data = data }
    }
}

/// One-time, user-requested catalog reset. Journal snapshots and drafts are retained.
enum PersonalSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] { PersonalSchemaV3.models + [MaintenanceRecord.self] }
    @Model final class MaintenanceRecord {
        @Attribute(.unique) var key: String
        init(_ key: String) { self.key = key }
    }
}

enum CatalogReset {
    static func apply(to container: ModelContainer) throws {
        let db = ModelContext(container); db.autosaveEnabled = false
        let key = "catalog-reset-2026-09-14"
        guard try db.fetch(FetchDescriptor<PersonalSchemaV4.MaintenanceRecord>(predicate: #Predicate { $0.key == key })).isEmpty else { return }
        do {
            try db.fetch(FetchDescriptor<PersonalSchema.PersonalProduct>()).forEach { db.delete($0) }
            try db.fetch(FetchDescriptor<PersonalSchemaV3.ChoiceRecord>()).forEach { db.delete($0) }
            db.insert(PersonalSchemaV4.MaintenanceRecord(key))
            try db.save()
        } catch { db.rollback(); throw error }
    }
}

/// Explicit maintenance command for the user's first real tracking day.
/// Not a migration: normal launches never invoke it. The marker prevents repeats.
enum HistoryReset {
    static func backupStore(at store: URL) throws -> URL {
        let files = FileManager.default
        let directory = store.deletingLastPathComponent()
            .appendingPathComponent("HistoryBackups/" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        // Called before ModelContainer opens the store; preserve SQLite's WAL as well.
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: store.path + suffix)
            if files.fileExists(atPath: source.path) {
                try files.copyItem(at: source, to: directory.appendingPathComponent(source.lastPathComponent))
            }
        }
        return directory
    }
    static func apply(to container: ModelContainer) throws {
        let db = ModelContext(container); db.autosaveEnabled = false
        let key = "history-reset-2026-09-15"
        guard try db.fetch(FetchDescriptor<PersonalSchemaV4.MaintenanceRecord>(predicate: #Predicate { $0.key == key })).isEmpty else { return }
        do {
            try db.fetch(FetchDescriptor<PersonalSchema.Record>()).forEach { db.delete($0) }
            try db.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>()).forEach { db.delete($0) }
            try db.fetch(FetchDescriptor<PersonalSchema.DraftRecord>()).forEach { db.delete($0) }
            try db.fetch(FetchDescriptor<PersonalSchemaV3.MealDraftRecord>()).forEach { db.delete($0) }
            try db.fetch(FetchDescriptor<PersonalSchemaV3.ChoiceRecord>()).forEach { db.delete($0) }
            // Goals, personal products, product drafts and catalog tombstones are untouched.
            db.insert(PersonalSchemaV4.MaintenanceRecord(key))
            try db.save()
        } catch { db.rollback(); throw error }
    }
}

enum PersonalMigration: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PersonalSchema.self, PersonalSchemaV2.self, PersonalSchemaV3.self, PersonalSchemaV4.self, PersonalSchemaV5.self, PersonalSchemaV6.self, PersonalSchemaV7.self, PersonalSchemaV8.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: PersonalSchema.self, toVersion: PersonalSchemaV2.self),
         .lightweight(fromVersion: PersonalSchemaV2.self, toVersion: PersonalSchemaV3.self),
         .lightweight(fromVersion: PersonalSchemaV3.self, toVersion: PersonalSchemaV4.self),
         .lightweight(fromVersion: PersonalSchemaV4.self, toVersion: PersonalSchemaV5.self),
         .lightweight(fromVersion: PersonalSchemaV5.self, toVersion: PersonalSchemaV6.self),
         .lightweight(fromVersion: PersonalSchemaV6.self, toVersion: PersonalSchemaV7.self),
         .custom(fromVersion: PersonalSchemaV7.self, toVersion: PersonalSchemaV8.self, willMigrate: nil,
             didMigrate: { try DraftStorage.migrate($0) })]
    }
}

@MainActor @Observable final class DiaryStore {
    let container: ModelContainer
    private let context: ModelContext
    let catalog: Catalog
    let productRepository: ProductRepository
    var selectedDay = Day(Date())
    var today = Day(Date())
    var items: [DiaryItem] = []
    var mealHistory: [DiaryItem] = []
    var goals: Nutrition?
    var currentGoals: Nutrition?
    var streak = 0
    var draft: FoodDraft?
    var error: String?
    var savedCount = 0
    var readIssues: [StoredDataIssue] = []
    @ObservationIgnored private var reloadID = UUID()
    @ObservationIgnored private lazy var reader = DiaryReader(container: container)
    var pageRevision = 0
    @ObservationIgnored private var presentationPages: [Day: DiaryPageData] = [:]
    var isShowingFood = false
    var catalogError: String?
    // Opt-in only for the real app, never for test containers.
    var publishesWidget = false
    // Injected only by tests, before a save. Production uses the actual persistent context.
    var beforeSave: (() throws -> Void)?

    init(container: ModelContainer, catalog: Catalog) {
        self.container = container; self.catalog = catalog
        productRepository = ProductRepository(container: container)
        context = ModelContext(container); context.autosaveEnabled = false
        do {
            // Initial page is bounded. Full presentation preparation runs on DiaryReader.
            draft = try DraftStorage.all(MealDraft.self, kind: .meal, db: context).values.first(where: { $0.legacyInput != nil })?.legacyInput
            let page = try Self.loadPage(for: selectedDay, context: context)
            items = page.items; goals = page.goals; currentGoals = page.goals; readIssues = page.issues
        } catch { self.error = error.localizedDescription }
    }
    static func makeContainer(memory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: PersonalSchemaV8.self)
        let config: ModelConfiguration
        if memory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            let location = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("default.store")
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            config = ModelConfiguration(schema: schema, url: location, cloudKitDatabase: .none)
        }
        let container = try ModelContainer(for: schema, migrationPlan: PersonalMigration.self, configurations: [config])
        let db = ModelContext(container); db.autosaveEnabled = false
        try DraftStorage.migrate(db)
        return container
    }
    private func save() throws { try beforeSave?(); try context.save() }
    private func transact(_ body: () throws -> Void) throws {
        do { try body(); try save() } catch { context.rollback(); throw error }
    }
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
    var total: Nutrition { items.filter { $0.row.timing?.isPlanned != true }.reduce(.zero) { $0 + $1.total } }
    var future: Bool { selectedDay > today }
    func select(_ day: Day, usePresentationCache: Bool = false) {
        do {
            let selected = try usePresentationCache ? presentationPage(for: day) : page(for: day)
            items = selected.items; goals = selected.goals; readIssues = selected.issues
            selectedDay = day
        } catch { self.error = error.localizedDescription }
    }
    func refreshClock(_ now: Date = Date()) {
        let newToday = Day(now)
        if newToday != today { today = newToday; selectedDay = newToday }
        Task { await reloadAsync() }
    }
    func page(for day: Day) throws -> DiaryPageData {
        try Self.loadPage(for: day, context: ModelContext(container))
    }
    func presentationPage(for day: Day) throws -> DiaryPageData {
        if let cached = presentationPages[day] { return cached }
        let loaded = try page(for: day)
        if presentationPages.count >= 5 { presentationPages.removeAll(keepingCapacity: true) }
        presentationPages[day] = loaded
        return loaded
    }
    nonisolated static func loadPage(for day: Day, context: ModelContext) throws -> DiaryPageData {
        let key = day.rawValue
        var loaded: [DiaryItem] = [], issues: [StoredDataIssue] = []
        func damaged(_ id: UUID, mealKey: String, reason: String) {
            let message = "Не удалось прочитать запись \(id). Исходные данные сохранены. " + reason
            issues.append(.init(id: id.uuidString, message: message))
            loaded.append(DiaryItem(id: id, day: day, meal: Meal(rawValue: mealKey) ?? .snack,
                row: MealRow(id: id, readError: message, food: "Повреждённая запись", matchAttention: "Питание неизвестно")))
        }
        let journal = try context.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>(predicate: #Predicate { $0.dayKey == key }))
        let ids = Set(journal.map(\.id))
        for record in journal {
            do {
                guard let meal = Meal(rawValue: record.mealKey) else { throw FoodError.database("Неизвестный приём пищи.") }
                let row = try JSONDecoder().decode(MealRow.self, from: record.data)
                guard row.id == record.id else { throw FoodError.database("Идентификаторы строки не совпадают.") }
                loaded.append(DiaryItem(id: record.id, day: day, meal: meal, row: row))
            } catch { damaged(record.id, mealKey: record.mealKey, reason: error.localizedDescription) }
        }
        for record in try context.fetch(FetchDescriptor<PersonalSchema.Record>(predicate: #Predicate { $0.dayKey == key })) where !ids.contains(record.id) {
            do {
                let product = try JSONDecoder().decode(Product.self, from: record.productData)
                guard let meal = Meal(rawValue: record.mealKey), let unit = Basis(rawValue: record.unit) else { throw FoodError.unknownBasis }
                let amount = try Numbers.parse(record.amount, positive: true)
                _ = try product.portion(amount, unit: unit)
                loaded.append(DiaryItem(id: record.id, day: day, meal: meal, product: product, amount: amount, unit: unit))
            } catch { damaged(record.id, mealKey: record.mealKey, reason: error.localizedDescription) }
        }
        loaded.sort { $0.row.displayName.localizedStandardCompare($1.row.displayName) == .orderedAscending }
        let history = try context.fetch(FetchDescriptor<PersonalSchema.GoalRecord>(sortBy: [SortDescriptor(\.effectiveDay)]))
        var goals: Nutrition?
        if let record = history.last(where: { $0.effectiveDay <= key }) {
            do { goals = try JSONDecoder().decode(Nutrition.self, from: record.data) }
            catch { issues.append(.init(id: "goals:" + record.effectiveDay, message: "Не удалось прочитать цели. Исходные данные сохранены.")) }
        }
        return DiaryPageData(items: loaded, goals: goals, issues: issues)
    }
    func reload() throws { apply(try DiaryReader.snapshot(container: container, selected: selectedDay, today: today)) }
    func reloadAsync() async {
        let id = UUID(); reloadID = id
        let selected = selectedDay, current = today
        do {
            let snapshot = try await reader.load(selected: selected, today: current)
            guard reloadID == id, selectedDay == selected, today == current else { return }
            apply(snapshot)
        } catch { guard reloadID == id else { return }; self.error = error.localizedDescription }
    }
    private func apply(_ snapshot: DiaryReloadSnapshot) {
        presentationPages = snapshot.pages
        if let page = snapshot.pages[selectedDay] { items = page.items; goals = page.goals }
        currentGoals = snapshot.pages[today]?.goals; mealHistory = snapshot.history
        streak = snapshot.streak; readIssues = snapshot.issues; pageRevision += 1
        #if os(iOS)
        if publishesWidget {
            do {
                let days = (0..<8).compactMap { offset -> NutritionWidgetDay? in
                    let day = today.offset(offset)
                    guard let page = snapshot.pages[day] else { return nil }
                    let sum = page.summary
                    func nutrient(_ key: KeyPath<Nutrition, Decimal>, _ missing: Int) -> WidgetNutrient {
                        WidgetNutrient(known: sum.known[keyPath: key], target: page.goals?[keyPath: key], missing: missing)
                    }
                    return NutritionWidgetDay(day: day.rawValue, calories: nutrient(\.calories, sum.missingCalories),
                        protein: nutrient(\.protein, sum.missingProtein), fat: nutrient(\.fat, sum.missingFat), carbs: nutrient(\.carbs, sum.missingCarbs))
                }
                if try NutritionWidgetCache.write(NutritionWidgetSnapshot(timeZone: TimeZone.autoupdatingCurrent.identifier, days: days)) {
                    for kind in NutritionWidgetSnapshot.allKinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
                    UsageTelemetry.shared.event("nutritionWidgetPublished", ["day": today.rawValue])
                }
            } catch { UsageTelemetry.shared.event("nutritionWidgetPublishFailed", ["error": String(describing: error)]) }
        }
        #endif
    }
    func setGoals(_ value: Nutrition) throws {
        for n in [value.calories, value.protein, value.fat, value.carbs] { _ = try Numbers.parse(Numbers.string(n), positive: true) }
        let all = try context.fetch(FetchDescriptor<PersonalSchema.GoalRecord>())
        let day = all.isEmpty ? "0001-01-01" : today.rawValue
        let data = try JSONEncoder().encode(value)
        try transact {
            if let row = all.first(where: { $0.effectiveDay == day }) { row.data = data }
            else { context.insert(PersonalSchema.GoalRecord(day: day, data: data)) }
            try StorageRevision.touch("goals", db: context)
        }
        try reload(); savedCount += 1
    }
    func persistDraft(_ value: FoodDraft?) throws {
        try transact {
            if var value {
                if value.draftID == nil { value.draftID = UUID() }
                let id = value.draftID!
                var modern = try DraftStorage.all(MealDraft.self, kind: .meal, db: context).values.first { $0.id == id }
                    ?? MealDraft(day: value.day, meal: value.meal)
                modern.id = id; modern.day = value.day; modern.meal = value.meal
                modern.editingEntryID = value.editingID; modern.legacyInput = value
                if modern.timing == nil { modern.timing = MealTiming(mode: value.day > today ? .planned : .now,
                    selectedAt: value.day > today ? value.day.date : nil) }
                if let product = value.product {
                    modern.rows = [MealRow(id: value.editingID ?? modern.rows.first?.id ?? UUID(), food: product.name,
                        quantity: value.quantity, unit: FoodUnit(rawValue: value.basis.rawValue), product: product)]
                }
                try DraftStorage.save(modern, id: id, kind: .meal, editingKey: value.editingID?.uuidString, db: context)
                draft = value
            } else if let id = draft?.draftID { try DraftStorage.close(id, kind: .meal, db: context) }
        }
        if value == nil { draft = nil }
    }
    func editDraft(_ change: (inout FoodDraft) -> Void) {
        guard var value = draft else { return }
        change(&value)
        // Preserve current input in memory even if disk save fails, then surface failure.
        draft = value
        perform { try persistDraft(value) }
    }
    func begin(_ meal: Meal) {
        perform { try persistDraft(FoodDraft(day: selectedDay, meal: meal)); isShowingFood = true }
    }
    func edit(_ item: DiaryItem) {
        guard let product = item.product, let amount = item.amount,
              let unit = item.unit.flatMap({ Basis(rawValue: $0.rawValue) }) else { return }
        perform {
            try persistDraft(FoodDraft(day: item.day, meal: item.meal, product: product,
                                      quantity: Numbers.string(amount), basis: unit, editingID: item.id))
            isShowingFood = true
        }
    }
    func choose(_ product: Product) {
        editDraft { $0.product = product; $0.basis = product.basis; $0.custom = false; $0.quantity = ""; $0.savesPersonalProduct = false }
    }
    func customProduct() {
        editDraft { value in
            value.custom = true
            if let p = value.product {
                value.customName = p.name; value.customBarcode = p.barcode ?? ""
                value.customCalories = p.calories.map(Numbers.string) ?? ""
                value.customProtein = p.protein.map(Numbers.string) ?? ""
                value.customFat = p.fat.map(Numbers.string) ?? ""
                value.customCarbs = p.carbs.map(Numbers.string) ?? ""
            } else if Barcode.valid(value.query) { value.customBarcode = value.query }
        }
    }
    func finishCustom() throws {
        guard let d = draft else { return }
        let name = d.customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FoodError.database("Укажите название продукта.") }
        let code = d.customBarcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.isEmpty || Barcode.valid(code) else { throw FoodError.invalidBarcode }
        guard d.basis != .unknown else { throw FoodError.unknownBasis }
        let product = Product(id: code.isEmpty ? (d.product?.id ?? UUID().uuidString) : code, barcode: code.isEmpty ? nil : code,
                              name: name, brand: "Моя карточка", basis: d.basis,
                              calories: try Numbers.parse(d.customCalories), protein: try Numbers.parse(d.customProtein),
                              fat: try Numbers.parse(d.customFat), carbs: try Numbers.parse(d.customCarbs), source: "user-label")
        var next = d; next.product = product; next.custom = false; next.savesPersonalProduct = true
        try persistDraft(next)
    }
    func commitDraft() throws {
        guard let d = draft, let draftID = d.draftID, var product = d.product else { throw FoodError.missingNutrition }
        let amount = try Numbers.parse(d.quantity, positive: true)
        product.basis = d.basis
        _ = try product.portion(amount, unit: d.basis)
        let data = try JSONEncoder().encode(product), id = d.editingID ?? UUID()
        let records = try context.fetch(FetchDescriptor<PersonalSchema.Record>(predicate: #Predicate { $0.id == id }))
        let journal = try context.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>(predicate: #Predicate { $0.id == id }))
        let personal = try context.fetch(FetchDescriptor<PersonalSchema.PersonalProduct>())
        var row = MealRow(id: id, food: product.name, quantity: Numbers.string(amount), unit: FoodUnit(rawValue: d.basis.rawValue), product: product)
        if let old = journal.first {
            let previous = try JSONDecoder().decode(MealRow.self, from: old.data)
            row.timing = previous.timing; row.batchPortions = previous.batchPortions
        } else {
            row.timing = MealTiming(mode: d.day > today ? .planned : .now, selectedAt: d.day > today ? d.day.date : nil).confirmed(rows: [row], day: d.day, now: Date())
        }
        row = try row.validated()
        let encoded = try JSONEncoder().encode(row)
        try transact {
            if row.timing?.isPlanned != true { try PreparedStorage.reconcile(row, db: context) }
            if (product.source == "user-label" && (d.savesPersonalProduct == true || !personal.contains(where: { $0.key == product.id }))) || d.product?.basis == .unknown {
                if let old = personal.first(where: { $0.key == product.id }) { old.data = data; old.name = product.name; old.barcode = product.barcode }
                else { context.insert(PersonalSchema.PersonalProduct(product, data: data)) }
                try StorageRevision.touch("products", db: context)
            }
            if let old = journal.first { old.data = encoded; old.dayKey = d.day.rawValue; old.mealKey = d.meal.rawValue }
            else { context.insert(PersonalSchemaV3.JournalRecord(id: id, day: d.day, meal: d.meal, data: encoded)) }
            records.forEach { context.delete($0) }
            try DraftStorage.close(draftID, kind: .meal, db: context)
            try StorageRevision.index(id: id, day: d.day.rawValue, row: row, db: context)
            try StorageRevision.touch("journal", db: context); try StorageRevision.touch("prepared", db: context)
        }
        draft = nil; isShowingFood = false; selectedDay = d.day
        try reload(); savedCount += 1
    }
    func remove(_ id: UUID) throws {
        let rows = try context.fetch(FetchDescriptor<PersonalSchema.Record>(predicate: #Predicate { $0.id == id }))
        let journal = try context.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>(predicate: #Predicate { $0.id == id }))
        try transact {
            try PreparedStorage.removeUse(id, db: context)
            rows.forEach { context.delete($0) }; journal.forEach { context.delete($0) }
            try StorageRevision.removeIndex(id, db: context)
            try StorageRevision.touch("journal", db: context); try StorageRevision.touch("prepared", db: context)
            if draft?.editingID == id, let draftID = draft?.draftID { try DraftStorage.close(draftID, kind: .meal, db: context) }
        }
        if draft?.editingID == id { draft = nil; isShowingFood = false }
        try reload()
    }
    func personalProducts() throws -> [Product] {
        try context.fetch(FetchDescriptor<PersonalSchema.PersonalProduct>()).map { try JSONDecoder().decode(Product.self, from: $0.data) }
    }
    func search(_ query: String) async throws -> [Product] {
        let own = try await productRepository.search(query)
        let external: [Product]
        do {
            external = try await catalog.search(query)
            catalogError = nil
        } catch {
            catalogError = "Каталог недоступен. Ваши продукты и дневник сохранены. " + error.localizedDescription
            external = []
        }
        try Task.checkCancellation()
        let hidden = try await productRepository.hiddenIDs()
        let overrides = try await productRepository.overrides(for: external)
        var seen = Set<String>()
        let prepared = try await productRepository.activePreparedProducts().filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
        }
        return (prepared + own + external.map { product in
            overrides.first { $0.id == product.id || ($0.barcode != nil && $0.barcode == product.barcode) } ?? product
        }).filter { !hidden.contains($0.id) && seen.insert($0.barcode ?? $0.id).inserted }.prefix(30).map { $0 }
    }

    /// User-facing search uses the same token, morphology and typo-aware index as
    /// voice matching. The literal path is retained for barcodes and as a bounded
    /// fallback, but an extra word can no longer hide an otherwise strong match.
    func rankedSearch(_ query: String) async throws -> [Product] {
        let requested = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return try await search("") }
        let literal = try await search(requested)
        if [8, 12, 13, 14].contains(requested.count), requested.allSatisfy(\.isNumber), !literal.isEmpty {
            return literal
        }
        let index = try await productRepository.searchIndex(catalog)
        let ranked = await Task.detached { index.rank(requested, history: []) }.value
        try Task.checkCancellation()
        var seen = Set<String>()
        return (ranked.map(\.product) + literal)
            .filter { seen.insert($0.barcode ?? $0.id).inserted }
            .prefix(30).map { $0 }
    }
}

/// Immutable daily SQLite snapshot, including committed WAL contents.
/// Destination is published only after the backup and integrity check succeed.
enum DailyStoreBackup {
    static func create(store: URL, root: URL, day: String) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: store.path) else { return nil }
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw FoodError.database("Неверная дата резервной копии") }
        let target = root.appendingPathComponent(day, isDirectory: true)
        if fm.fileExists(atPath: target.appendingPathComponent("complete.json").path) { return nil }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("pending-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var source: OpaquePointer?, destination: OpaquePointer?
        defer { sqlite3_close(source); sqlite3_close(destination) }
        guard sqlite3_open_v2(store.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(staging.appendingPathComponent("default.store").path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw FoodError.database("Не удалось открыть базу для резервной копии")
        }
        sqlite3_busy_timeout(source, 1000); sqlite3_busy_timeout(destination, 1000)
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else { throw FoodError.database("Не удалось начать резервную копию") }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw FoodError.database("База занята: резервная копия будет повторена при открытии") }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(destination, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let answer = sqlite3_column_text(statement, 0), String(cString: answer) == "ok" else { throw FoodError.database("Проверка резервной копии не прошла") }
        sqlite3_finalize(statement); statement = nil
        sqlite3_close(destination); destination = nil
        let file = staging.appendingPathComponent("default.store")
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.synchronize()
        let metadata = ["day": day, "createdAt": MatchingLog.timestamp(), "format": "sqlite-online-backup-v1"]
        try JSONEncoder().encode(metadata).write(to: staging.appendingPathComponent("complete.json"), options: .atomic)
        // Never remove or replace an existing backup, even an incomplete one.
        try fm.moveItem(at: staging, to: target)
        return target
    }
}
