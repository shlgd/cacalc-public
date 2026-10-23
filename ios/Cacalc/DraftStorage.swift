import Foundation
import SwiftData

/// V1–V7 models stay unchanged. One address belongs to one unfinished operation.
enum PersonalSchemaV8: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(8, 0, 0) }
    static var models: [any PersistentModel.Type] {
        PersonalSchemaV7.models + [WorkDraft.self, RevisionRecord.self, JournalIndex.self, ConsumedDay.self]
    }
    @Model final class WorkDraft {
        @Attribute(.unique) var id: UUID
        var kind: String
        var editingKey: String?
        var data: Data
        var updatedAt: Date
        var closed: Bool
        var legacyKey: String?
        init(id: UUID, kind: String, editingKey: String?, data: Data, legacyKey: String? = nil) {
            self.id = id; self.kind = kind; self.editingKey = editingKey; self.data = data
            self.legacyKey = legacyKey; updatedAt = Date(); closed = false
        }
    }
    @Model final class RevisionRecord {
        @Attribute(.unique) var key: String
        var token: String
        init(_ key: String) { self.key = key; token = UUID().uuidString }
    }
    @Model final class ConsumedDay {
        @Attribute(.unique) var dayKey: String
        var count: Int
        var unreadable: Int
        init(_ day: String) { dayKey = day; count = 0; unreadable = 0 }
    }
    /// Indexed metadata avoids decoding years of JSON for streaks and episode queries.
    @Model final class JournalIndex {
        @Attribute(.unique) var id: UUID
        var dayKey: String
        var episodeID: UUID?
        var status: String
        init(id: UUID, day: String, row: MealRow?) {
            self.id = id; dayKey = day; episodeID = row?.timing?.episodeID
            status = row.map { $0.timing?.isPlanned == true ? "planned" : "consumed" } ?? "unreadable"
        }
    }
}

struct DraftCollection<Value: Sendable>: Sendable {
    var values: [Value] = []
    var issues: [StoredDataIssue] = []
}
enum DraftKind: String, Sendable { case product, meal, cooking, combination }

struct DraftOperation: Equatable, Sendable {
    var draftID: UUID
    var revision: UUID
    var operationID: UUID
}

enum StorageRevision {
    static func token(_ key: String, db: ModelContext) throws -> String {
        try db.fetch(FetchDescriptor<PersonalSchemaV8.RevisionRecord>(predicate: #Predicate { $0.key == key })).first?.token ?? "initial"
    }
    static func touch(_ key: String, db: ModelContext) throws {
        if let value = try db.fetch(FetchDescriptor<PersonalSchemaV8.RevisionRecord>(predicate: #Predicate { $0.key == key })).first {
            value.token = UUID().uuidString
        } else { db.insert(PersonalSchemaV8.RevisionRecord(key)) }
    }
    private static func changeDay(_ day: String, status: String, delta: Int, db: ModelContext) throws {
        guard status != "planned" else { return }
        let value: PersonalSchemaV8.ConsumedDay
        if let old = try db.fetch(FetchDescriptor<PersonalSchemaV8.ConsumedDay>(predicate: #Predicate { $0.dayKey == day })).first { value = old }
        else { value = PersonalSchemaV8.ConsumedDay(day); db.insert(value) }
        if status == "consumed" { value.count += delta } else { value.unreadable += delta }
    }
    static func index(id: UUID, day: String, row: MealRow?, db: ModelContext) throws {
        let row = row.flatMap { $0.id == id ? $0 : nil }
        let status = row.map { $0.timing?.isPlanned == true ? "planned" : "consumed" } ?? "unreadable"
        if let old = try db.fetch(FetchDescriptor<PersonalSchemaV8.JournalIndex>(predicate: #Predicate { $0.id == id })).first {
            if old.dayKey != day || old.status != status {
                try changeDay(old.dayKey, status: old.status, delta: -1, db: db)
                try changeDay(day, status: status, delta: 1, db: db)
            }
            old.dayKey = day; old.episodeID = row?.timing?.episodeID; old.status = status
        } else {
            db.insert(PersonalSchemaV8.JournalIndex(id: id, day: day, row: row))
            try changeDay(day, status: status, delta: 1, db: db)
        }
    }
    static func removeIndex(_ id: UUID, db: ModelContext) throws {
        for old in try db.fetch(FetchDescriptor<PersonalSchemaV8.JournalIndex>(predicate: #Predicate { $0.id == id })) {
            try changeDay(old.dayKey, status: old.status, delta: -1, db: db); db.delete(old)
        }
    }

}

enum DraftStorage {
    static func all<T: Decodable & Sendable>(_ type: T.Type, kind: DraftKind, db: ModelContext) throws -> DraftCollection<T> {
        let key = kind.rawValue
        let records = try db.fetch(FetchDescriptor<PersonalSchemaV8.WorkDraft>(
            predicate: #Predicate { $0.kind == key && !$0.closed }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        var result = DraftCollection<T>()
        for record in records {
            do { result.values.append(try JSONDecoder().decode(type, from: record.data)) }
            catch { result.issues.append(.init(id: record.id.uuidString,
                message: "Не удалось прочитать черновик \(record.id). Исходные данные сохранены.")) }
        }
        return result
    }
    static func save<T: Encodable>(_ value: T, id: UUID, kind: DraftKind, editingKey: String?, db: ModelContext) throws {
        let data = try JSONEncoder().encode(value)
        if let old = try db.fetch(FetchDescriptor<PersonalSchemaV8.WorkDraft>(predicate: #Predicate { $0.id == id })).first {
            guard !old.closed, old.kind == kind.rawValue else {
                throw FoodError.database("Этот черновик уже завершён. Запоздалый результат не применён.")
            }
            old.data = data; old.editingKey = editingKey; old.updatedAt = Date()
        } else {
            db.insert(PersonalSchemaV8.WorkDraft(id: id, kind: kind.rawValue, editingKey: editingKey, data: data))
        }
    }
    static func close(_ id: UUID, kind: DraftKind, db: ModelContext) throws {
        let record = try db.fetch(FetchDescriptor<PersonalSchemaV8.WorkDraft>(predicate: #Predicate { $0.id == id })).first
        if let record {
            guard record.kind == kind.rawValue else { throw FoodError.database("Другой тип черновика.") }
            record.closed = true; record.data = Data(); record.updatedAt = Date()
        } else {
            let tombstone = PersonalSchemaV8.WorkDraft(id: id, kind: kind.rawValue, editingKey: nil, data: Data())
            tombstone.closed = true; db.insert(tombstone)
        }
    }
    static func completed<T: Decodable & Equatable>(_ value: T, id: UUID, kind: DraftKind, db: ModelContext) throws -> Bool {
        guard let stored = try db.fetch(FetchDescriptor<PersonalSchemaV8.WorkDraft>(predicate: #Predicate { $0.id == id })).first,
              stored.closed else { return false }
        guard stored.kind == kind.rawValue, let receipt = try? JSONDecoder().decode(T.self, from: stored.data), receipt == value else {
            throw FoodError.database("Этот черновик уже завершён. Запоздалый результат не применён.")
        }
        return true
    }
    static func finish<T: Encodable>(_ value: T, id: UUID, kind: DraftKind, db: ModelContext) throws {
        try close(id, kind: kind, db: db)
        let receipt = try db.fetch(FetchDescriptor<PersonalSchemaV8.WorkDraft>(predicate: #Predicate { $0.id == id })).first!
        receipt.data = try JSONEncoder().encode(value)
    }
    static func audioIsReferenced(_ file: String, db: ModelContext) throws -> Bool {
        // Includes unreadable payloads: never remove their only audio on a decode error.
        let needle = Data(file.utf8)
        return try db.fetch(FetchDescriptor<PersonalSchemaV8.WorkDraft>(predicate: #Predicate { !$0.closed }))
            .contains { $0.data.range(of: needle) != nil }
    }
    static func migrate(_ db: ModelContext) throws {
        // A marker also allows a V8 container opened without a migration plan to finish
        // legacy handoff exactly once. Old tables become immutable, never active writers.
        let marker = "draft-handoff-v8"
        guard try db.fetch(FetchDescriptor<PersonalSchemaV4.MaintenanceRecord>(predicate: #Predicate { $0.key == marker })).isEmpty else { return }
        func insert<T: Encodable>(_ value: T, id: UUID, kind: DraftKind, editing: String?, legacy: String) throws {
            db.insert(PersonalSchemaV8.WorkDraft(id: id, kind: kind.rawValue, editingKey: editing,
                data: try JSONEncoder().encode(value), legacyKey: legacy))
        }
        func damaged(_ data: Data, kind: DraftKind, legacy: String) {
            db.insert(PersonalSchemaV8.WorkDraft(id: UUID(), kind: kind.rawValue, editingKey: nil, data: data, legacyKey: legacy))
        }
        func decode<T: Decodable>(_ type: T.Type, data: Data, kind: DraftKind, legacy: String) -> T? {
            do { return try JSONDecoder().decode(type, from: data) }
            catch { damaged(data, kind: kind, legacy: legacy); return nil }
        }
        for record in try db.fetch(FetchDescriptor<PersonalSchemaV2.ProductDraftRecord>()) {
            if var value = decode(ProductCreationDraft.self, data: record.data, kind: .product, legacy: record.key) {
                value.productID = value.editingProductID ?? value.id.uuidString
                try insert(value, id: value.id, kind: .product, editing: value.editingProductID, legacy: record.key)
            }
        }
        for record in try db.fetch(FetchDescriptor<PersonalSchemaV3.MealDraftRecord>()) {
            if let value = decode(MealDraft.self, data: record.data, kind: .meal, legacy: record.key) {
                try insert(value, id: value.id, kind: .meal, editing: value.editingEntryID?.uuidString, legacy: record.key)
            }
        }
        for record in try db.fetch(FetchDescriptor<PersonalSchemaV5.CookingDraft>()) {
            if var value = decode(CookingState.self, data: record.data, kind: .cooking, legacy: record.key) {
                value.draftID = UUID()
                try insert(value, id: value.id, kind: .cooking,
                    editing: value.templateOnly == true ? value.recipe.id.uuidString : nil, legacy: record.key)
            }
        }
        for record in try db.fetch(FetchDescriptor<PersonalSchema.DraftRecord>()) {
            if let old = decode(FoodDraft.self, data: record.data, kind: .meal, legacy: record.key) {
                var value = MealDraft(day: old.day, meal: old.meal)
                value.id = old.draftID ?? value.id
                value.editingEntryID = old.editingID
                value.timing = MealTiming(mode: old.day > Day(Date()) ? .planned : .now,
                    selectedAt: old.day > Day(Date()) ? old.day.date : nil)
                var original = old; original.draftID = value.id; value.legacyInput = original
                var product = old.product
                if old.custom {
                    var card = ProductCreationDraft()
                    card.name = old.customName; card.barcode = old.customBarcode; card.basis = old.basis
                    card.calories = old.customCalories; card.protein = old.customProtein; card.fat = old.customFat; card.carbs = old.customCarbs
                    card.editingProductID = old.product?.id
                    value.linkingProductDraftID = card.id
                    value.linkingProductID = card.editingProductID ?? card.productID
                    try insert(card, id: card.id, kind: .product, editing: card.editingProductID, legacy: "food-card:" + record.key)
                    product = nil
                }
                if old.custom || product != nil || !old.query.isEmpty || old.editingID != nil {
                    let title = old.custom ? (old.customName.isEmpty ? "Новый продукт" : old.customName) : (product?.name ?? old.query)
                    let row = MealRow(id: old.editingID ?? UUID(), food: title,
                        quantity: old.quantity, unit: FoodUnit(rawValue: old.basis.rawValue), product: product)
                    value.rows = [row]
                    if old.custom { value.linkingRowID = row.id }
                }
                if let id = old.editingID,
                   let saved = try db.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>(predicate: #Predicate { $0.id == id })).first {
                    if let row = try? JSONDecoder().decode(MealRow.self, from: saved.data) { value.timing = row.timing }
                }
                try insert(value, id: value.id, kind: .meal, editing: old.editingID?.uuidString, legacy: record.key)
            }
        }
        for record in try db.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>()) {
            let row = try? JSONDecoder().decode(MealRow.self, from: record.data)
            try StorageRevision.index(id: record.id, day: record.dayKey, row: row, db: db)
        }
        db.insert(PersonalSchemaV4.MaintenanceRecord(marker))
        try db.save()
    }
}

/// Exactly one running write and one replaceable latest snapshot per ID.
/// Events stay in the domain outbox; flush is a durability barrier, not a debounce.
@MainActor final class DraftWriter<Value: Sendable & Equatable> {
    private var latest: [UUID: Value] = [:]
    private var written: [UUID: Value] = [:]
    private var worker: Task<Void, Never>?
    private var writingID: UUID?
    private let write: @Sendable (Value) async throws -> Void
    private let failed: @MainActor (Error) -> Void
    private var failure: Error?
    private(set) var writes = 0
    private(set) var peakPending = 0
    init(write: @escaping @Sendable (Value) async throws -> Void, failed: @escaping @MainActor (Error) -> Void) {
        self.write = write; self.failed = failed
    }
    func submit(_ value: Value, id: UUID) {
        if written[id] == value && latest[id] == nil && writingID != id { return }
        latest[id] = value; peakPending = max(peakPending, latest.count)
        guard worker == nil else { return }
        worker = Task {
            // Merge synchronous field changes before starting I/O.
            await Task.yield()
            while let (id, value) = latest.first {
                latest[id] = nil
                if written[id] == value { continue }
                writingID = id
                defer { writingID = nil }
                do { try await write(value); written[id] = value; writes += 1; failure = nil }
                catch {
                    if latest[id] == nil { latest[id] = value }
                    failure = error; failed(error); break
                }
            }
            worker = nil
        }
    }
    func flush() async throws {
        var retries = 1
        while true {
            await worker?.value
            if let failure {
                guard retries > 0 else { throw failure }
                retries -= 1; self.failure = nil
            }
            if worker == nil && latest.isEmpty { return }
            if worker == nil, let (id, value) = latest.first { submit(value, id: id) }
        }
    }
    func forget(_ id: UUID) {
        // Completion/discard callers first pass the flush barrier.
        precondition(writingID != id && latest[id] == nil)
        written[id] = nil
    }
}

/// Background autosave for recipes/cooking and combinations, using the same addresses
/// as their final transactional repository. No live UI context crosses executors.
actor WorkDraftRepository {
    private let container: ModelContainer
    init(container: ModelContainer) { self.container = container }
    func persist(_ state: CookingState) throws {
        try persist(state, id: state.id, kind: .cooking,
            editingKey: state.templateOnly == true ? state.recipe.id.uuidString : nil)
    }
    func persist(_ state: CombinationDraft) throws {
        try persist(state, id: state.id, kind: .combination, editingKey: state.editingID?.uuidString)
    }
    private func persist<T: Encodable>(_ value: T, id: UUID, kind: DraftKind, editingKey: String?) throws {
        let db = ModelContext(container); db.autosaveEnabled = false
        do { try DraftStorage.save(value, id: id, kind: kind, editingKey: editingKey, db: db); try db.save() }
        catch { db.rollback(); throw error }
    }
}
