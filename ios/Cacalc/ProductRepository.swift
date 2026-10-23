import Foundation
import SwiftData
import Observation

/// Explicit, one-time import from the user's cream nutrition table (values per 100 g).
/// It never replaces an existing personal card, draft, or diary entry.
enum CreamTableImport {
    static let launchArgument = "--import-cream-table-2026-09-29"
    private static let marker = "personal-cream-table-2026-09-29"
    private struct Entry {
        let percent: Int
        let calories: String
        let protein: String
        let fat: String
        let carbs: String
        var name: String { "Сливки \(percent)%" }
        var id: String { "personal:cream-table-2026-09-29:\(percent)" }
    }
    private static let entries: [Entry] = [
        .init(percent: 10, calories: "119", protein: "2,7", fat: "10", carbs: "4,2"),
        .init(percent: 15, calories: "161", protein: "2,6", fat: "15", carbs: "3,9"),
        .init(percent: 20, calories: "206", protein: "2,6", fat: "20", carbs: "4,0"),
        .init(percent: 22, calories: "224", protein: "2,5", fat: "22", carbs: "4,0"),
        .init(percent: 25, calories: "250", protein: "2,4", fat: "25", carbs: "3,5"),
        .init(percent: 30, calories: "297", protein: "2,2", fat: "30", carbs: "4,5"),
        .init(percent: 33, calories: "319", protein: "2,2", fat: "33", carbs: "3,2")
    ]

    static func apply(to container: ModelContainer) throws -> Int {
        let db = ModelContext(container); db.autosaveEnabled = false
        let key = marker
        if try !db.fetch(FetchDescriptor<PersonalSchemaV4.MaintenanceRecord>(predicate: #Predicate { $0.key == key })).isEmpty {
            return 0
        }
        let existing = try db.fetch(FetchDescriptor<PersonalSchema.PersonalProduct>())
        let names = Set(try existing.map { try JSONDecoder().decode(Product.self, from: $0.data) }
            .filter { $0.brand.isEmpty }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase })
        guard !entries.contains(where: { entry in
            names.contains(entry.name.localizedLowercase) || existing.contains(where: { $0.key == entry.id })
        }) else {
            throw FoodError.database("В личных продуктах уже есть одна из карточек сливок. Импорт остановлен без изменений.")
        }
        do {
            for entry in entries {
                let product = Product(id: entry.id, barcode: nil, name: entry.name, brand: "", basis: .g,
                    calories: try Numbers.parse(entry.calories), protein: try Numbers.parse(entry.protein),
                    fat: try Numbers.parse(entry.fat), carbs: try Numbers.parse(entry.carbs), source: "user-label")
                db.insert(PersonalSchema.PersonalProduct(product, data: try JSONEncoder().encode(product)))
            }
            db.insert(PersonalSchemaV4.MaintenanceRecord(marker))
            try StorageRevision.touch("products", db: db)
            try db.save()
            return entries.count
        } catch { db.rollback(); throw error }
    }
}

/// The context is created on this actor's executor, never on the UI thread.
actor ProductRepository {
    private let container: ModelContainer
    private var cachedIndex: SearchIndex?
    private var cachedStamp: String?
    private(set) var readIssues: [StoredDataIssue] = []
    var failNextSave = false
    init(container: ModelContainer) { self.container = container }
    private func database() -> ModelContext {
        let value = ModelContext(container); value.autosaveEnabled = false
        return value
    }
    func injectSaveFailure() { failNextSave = true }
    private func save(_ db: ModelContext) throws {
        if failNextSave { failNextSave = false; throw FoodError.database("Тестовая ошибка сохранения") }
        try db.save()
    }
    // Versioned key namespace in the existing persistent maintenance registry.
    // A tombstone hides a catalogue ID without changing any diary snapshots.
    func hiddenIDs() throws -> Set<String> {
        let prefix = "hidden-product-v1:"
        return Set(try database().fetch(FetchDescriptor<PersonalSchemaV4.MaintenanceRecord>())
            .map(\.key).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }
    func remove(_ product: Product) throws {
        let db = database(), id = product.id, key = "hidden-product-v1:" + product.id
        do {
            if try db.fetch(FetchDescriptor<PersonalSchemaV4.MaintenanceRecord>(predicate: #Predicate { $0.key == key })).isEmpty {
                db.insert(PersonalSchemaV4.MaintenanceRecord(key))
            }
            try db.fetch(FetchDescriptor<PersonalSchema.PersonalProduct>(predicate: #Predicate { $0.key == id })).forEach { db.delete($0) }
            try StorageRevision.touch("products", db: db)
            try save(db)
        } catch { db.rollback(); throw error }
    }
    func searchIndex(_ catalog: Catalog) async throws -> SearchIndex {
        let db = database()
        let stamp = try StorageRevision.token("products", db: db) + StorageRevision.token("prepared", db: db)
        if let cachedIndex, cachedStamp == stamp { return cachedIndex }
        let products = try await availableCatalog(catalog)
        let index = SearchIndex(products: products)
        await SemanticProductSearch.shared.reconcileCatalog(products)
        let latest = database()
        let latestStamp = try StorageRevision.token("products", db: latest) + StorageRevision.token("prepared", db: latest)
        if latestStamp == stamp { cachedStamp = stamp; cachedIndex = index }
        else { return try await searchIndex(catalog) }
        return index
    }
    func activePreparedProducts() throws -> [Product] {
        let snapshot = try PreparedStorage.snapshot(database()); readIssues += snapshot.issues
        return snapshot.stocks.filter(\.active).map { $0.product }
    }
    func availableCatalog(_ catalog: Catalog) async throws -> [Product] {
        let base = try await catalog.browse()
        let own = try search("", limit: nil), hidden = try hiddenIDs()
        var seen = Set<String>()
        return (try activePreparedProducts() + own + base).filter { !hidden.contains($0.id) && seen.insert($0.id).inserted }
    }
    func drafts() throws -> DraftCollection<ProductCreationDraft> {
        try DraftStorage.all(ProductCreationDraft.self, kind: .product, db: database())
    }
    func loadDraft() throws -> ProductCreationDraft? { try drafts().values.first }
    func persist(_ draft: ProductCreationDraft) throws {
        let db = database()
        do {
            try DraftStorage.save(draft, id: draft.id, kind: .product, editingKey: draft.editingProductID, db: db)
            try save(db)
        } catch { db.rollback(); throw error }
    }
    func discardDraft(_ id: UUID) throws {
        let db = database()
        do { try DraftStorage.close(id, kind: .product, db: db); try save(db) }
        catch { db.rollback(); throw error }
    }
    func audioIsReferenced(_ file: String) throws -> Bool { try DraftStorage.audioIsReferenced(file, db: database()) }
    func search(_ text: String, limit: Int? = 50) throws -> [Product] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let predicate = #Predicate<PersonalSchema.PersonalProduct> {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.barcode == query
        }
        var request = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.name)])
        if let limit { request.fetchLimit = limit }
        var values: [Product] = [], issues: [StoredDataIssue] = []
        for record in try database().fetch(request) {
            do { values.append(try JSONDecoder().decode(Product.self, from: record.data)) }
            catch { issues.append(.init(id: record.key, message: "Карточка \(record.key) не прочитана. Исходные данные сохранены.")) }
        }
        readIssues = issues
        return values
    }
    func product(barcode: String) throws -> Product? {
        var request = FetchDescriptor<PersonalSchema.PersonalProduct>(predicate: #Predicate { $0.barcode == barcode })
        request.fetchLimit = 1
        return try database().fetch(request).first.map { try JSONDecoder().decode(Product.self, from: $0.data) }
    }
    func product(id: String) throws -> Product? {
        var request = FetchDescriptor<PersonalSchema.PersonalProduct>(predicate: #Predicate { $0.key == id })
        request.fetchLimit = 1
        return try database().fetch(request).first.map { try JSONDecoder().decode(Product.self, from: $0.data) }
    }
    func commit(_ draft: ProductCreationDraft) throws -> Product {
        let product = try draft.product(), id = product.id, code = product.barcode
        guard try !hiddenIDs().contains(id) else { throw FoodError.database("Карточка удалена. Создайте новую карточку.") }
        let db = database()
        if try DraftStorage.completed(draft, id: draft.id, kind: .product, db: db) { return product }
        let candidates = try db.fetch(FetchDescriptor<PersonalSchema.PersonalProduct>(predicate: #Predicate {
            $0.key == id || (code != nil && $0.barcode == code)
        }))
        guard !candidates.contains(where: { $0.key != id && $0.barcode == code && code != nil }) else {
            throw FoodError.database("Этот штрихкод уже есть в ваших продуктах. Откройте существующую карточку для изменения.")
        }
        let data = try JSONEncoder().encode(product)
        do {
            let row: PersonalSchema.PersonalProduct
            if let existing = candidates.first(where: { $0.key == id }) { row = existing; row.data = data; row.barcode = code }
            else { row = PersonalSchema.PersonalProduct(product, data: data); db.insert(row) }
            // Searchable metadata; the display title stays in the encoded product.
            row.name = [product.name, product.brand, product.manufacturer ?? ""].joined(separator: " ")
            try DraftStorage.finish(draft, id: draft.id, kind: .product, db: db)
            try StorageRevision.touch("products", db: db)
            try save(db)
            return product
        } catch { db.rollback(); throw error }
    }
    func overrides(for products: [Product]) throws -> [Product] {
        guard !products.isEmpty else { return [] }
        let ids = products.map(\.id), codes = products.compactMap(\.barcode).map(Optional.some)
        let request = FetchDescriptor<PersonalSchema.PersonalProduct>(predicate: #Predicate {
            ids.contains($0.key) || codes.contains($0.barcode)
        })
        var values: [Product] = []
        for record in try database().fetch(request) {
            do { values.append(try JSONDecoder().decode(Product.self, from: record.data)) }
            catch { readIssues.append(.init(id: record.key, message: "Карточка \(record.key) не прочитана. Исходные данные сохранены.")) }
        }
        return values
    }
}

enum ProductScope: String, CaseIterable, Identifiable {
    case all, basic, mine
    var id: Self { self }
    var title: String {
        switch self { case .all: "Все"; case .basic: "Базовые"; case .mine: "Мои" }
    }
    func includes(_ product: Product) -> Bool {
        switch self {
        case .all: true
        case .basic: product.id.hasPrefix("basic:")
        case .mine: product.source == "user-label" && !product.id.hasPrefix("basic:")
        }
    }
}

@MainActor @Observable final class ProductLibrary {
    let repository: ProductRepository
    var products: [Product] = []
    var drafts: [ProductCreationDraft] = []
    var draft: ProductCreationDraft?
    var showingEditor = false
    var error: String?
    var busy = false
    var savedCount = 0
    private var loaded = false
    private let catalog: Catalog?
    private var searchID = UUID()
    // Chain writes so an older autosave can never replace a newer draft or resurrect a saved one.
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var loadingID: UUID?
    @ObservationIgnored private var writer: DraftWriter<ProductCreationDraft>!
    init(container: ModelContainer, catalog: Catalog? = nil) {
        repository = ProductRepository(container: container); self.catalog = catalog
        let persistence = repository
        writer = DraftWriter(write: { value in try await persistence.persist(value) },
            failed: { [weak self] error in self?.error = "Черновик пока не сохранён на диск. " + error.localizedDescription })
    }
    func load() async {
        guard !loaded else { return }
        if let loading { await loading.value; return }
        let requestID = UUID(); loadingID = requestID
        let task = Task {
            do {
                let collection = try await repository.drafts()
                drafts = collection.values; draft = drafts.first; loaded = true
                if !collection.issues.isEmpty { error = collection.issues.map(\.message).joined(separator: "\n") }
                await search("")
            } catch { self.error = error.localizedDescription }
        }
        loading = task
        await task.value
        if loadingID == requestID { loading = nil; loadingID = nil }
    }
    func resume(_ id: UUID) async {
        guard !busy else { return }
        do {
            try await flush()
            let values = try await repository.drafts()
            drafts = values.values
            guard let value = drafts.first(where: { $0.id == id }) else { throw FoodError.database("Черновик не найден.") }
            draft = value; showingEditor = true
        } catch { self.error = error.localizedDescription }
    }
    func search(_ query: String) async {
        let requestID = UUID(); searchID = requestID
        do {
            let own = try await repository.search(query, limit: nil)
            let base = try await catalog?.browse(query) ?? []
            let edits = try await repository.overrides(for: base)
            let byID = Dictionary(edits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            let hidden = try await repository.hiddenIDs()
            let result = (own + base.map { byID[$0.id] ?? $0 })
                .filter { !hidden.contains($0.id) && seen.insert($0.id).inserted }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            try Task.checkCancellation()
            guard searchID == requestID else { return }
            products = result
            let issues = await repository.readIssues
            if !issues.isEmpty { error = issues.map(\.message).joined(separator: "\n") }
        } catch is CancellationError {} catch {
            guard searchID == requestID else { return }
            self.error = error.localizedDescription
        }
    }
    func remove(_ product: Product, query: String) async {
        do {
            try await repository.remove(product)
            await search(query)
        } catch { self.error = error.localizedDescription }
    }
    func begin(_ product: Product? = nil) async {
        guard !busy else { return }
        await load()
        guard loaded else { return }
        do {
            try await flush()
            drafts = try await repository.drafts().values
            if let product, let existing = drafts.first(where: { $0.editingProductID == product.id }) {
                draft = existing
            } else {
                draft = product.map(ProductCreationDraft.init) ?? ProductCreationDraft()
                changed()
                try await flush()
            }
            showingEditor = true
        } catch { self.error = error.localizedDescription }
    }
    func changed() {
        guard var value = draft else { return }
        value.revision = UUID(); draft = value
        if let i = drafts.firstIndex(where: { $0.id == value.id }) { drafts[i] = value }
        else { drafts.insert(value, at: 0) }
        writer.submit(value, id: value.id)
    }
    func flush() async throws {
        if let draft { writer.submit(draft, id: draft.id) }
        try await writer.flush()
    }
    func close() async {
        do { try await flush(); showingEditor = false }
        catch { self.error = error.localizedDescription }
    }
    func beginOperation() -> ProductCreationDraft? {
        guard var value = draft else { return nil }
        value.operationID = UUID(); value.revision = value.revision ?? UUID(); draft = value
        writer.submit(value, id: value.id)
        return value
    }
    func owns(_ value: ProductCreationDraft) -> Bool {
        !Task.isCancelled && draft?.id == value.id && draft?.revision == value.revision && draft?.operationID == value.operationID
    }
    private func removeAudio(_ file: String?) async throws {
        if let file, try await !repository.audioIsReferenced(file) { VoiceFiles.remove(file) }
    }
    func scan(_ code: String, catalog: Catalog) async -> String? {
        guard !busy, let original = beginOperation() else { return nil }
        busy = true
        defer { busy = false }
        do {
            guard Barcode.valid(code) else { throw FoodError.invalidBarcode }
            if let existing = try await repository.product(barcode: code), existing.id != original.editingProductID {
                throw FoodError.database("Этот штрихкод уже у «\(existing.name)». Откройте эту карточку в «Продуктах» для изменения. Текущий черновик не изменён.")
            }
            guard owns(original) else { return nil }
            draft?.barcode = code
            changed()
            guard let scanned = draft else { return nil }
            // Persist the useful scan before attempting a catalog lookup, which may fail.
            try await flush()
            let match: Product?
            do {
                let hidden = try await repository.hiddenIDs()
                match = try await catalog.search(code).first { $0.barcode == code && !hidden.contains($0.id) }
            }
            catch { return "Штрихкод сохранён. Каталог недоступен — название можно продиктовать." }
            guard owns(scanned) else { return nil }
            guard let match else { return "Штрихкод сохранён. Товара нет в каталоге — название можно продиктовать." }
            let filled = draft?.fillIdentity(from: match) == true
            if filled { changed(); try await flush() }
            return filled ? "Название и марка из каталога. Проверьте по упаковке." : "Штрихкод сохранён. Введённые поля оставлены."
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
    func commit() async {
        guard !busy, let value = draft else { return }
        busy = true
        defer { busy = false }
        do {
            try await flush()
            _ = try await repository.commit(value)
            writer.forget(value.id)
            drafts.removeAll { $0.id == value.id }; draft = nil; showingEditor = false; savedCount += 1
            try await removeAudio(value.audioFile)
            await search("")
        } catch { self.error = error.localizedDescription }
    }
    func discard() async {
        guard !busy, let value = draft else { return }
        busy = true
        defer { busy = false }
        do {
            try await writer.flush()
            try await repository.discardDraft(value.id)
            writer.forget(value.id)
            drafts.removeAll { $0.id == value.id }; draft = nil; showingEditor = false
            try await removeAudio(value.audioFile)
        } catch { self.error = error.localizedDescription }
    }
}
