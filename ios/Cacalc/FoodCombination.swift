import Foundation
import SwiftData

/// A reusable composition. Recipe references intentionally do not identify a cooked batch.
struct CombinationComponent: Codable, Equatable, Identifiable, Sendable {
    enum Source: Codable, Equatable, Sendable {
        case product(Product)
        case recipe(id: UUID, name: String)
    }
    var id = UUID()
    var source: Source
    var quantity = ""
    var portions = "1"
    var name: String {
        switch source { case .product(let product): product.name; case .recipe(_, let name): name }
    }
    var recipeID: UUID? { if case .recipe(let id, _) = source { id } else { nil } }
    var unit: FoodUnit {
        if case .product(let product) = source, product.basis == .ml { return .ml }
        return .g
    }
    func validate() throws {
        let grams = try Numbers.parse(quantity, positive: true)
        guard grams <= 1_000_000 else { throw FoodError.invalidNumber }
        switch source {
        case .product(let product):
            guard product.preparedBatchID == nil, product.basis == .g || product.basis == .ml else { throw FoodError.unknownBasis }
        case .recipe:
            let count = try Numbers.parse(portions, positive: true)
            guard count <= 1000 else { throw FoodError.invalidNumber }
        }
    }
    func candidates(_ stocks: [BatchStock]) -> [BatchStock] {
        guard let recipeID else { return [] }
        return stocks.filter { $0.active && $0.batch.recipe.id == recipeID }
    }
    func row(stocks: [BatchStock], selectedBatch: UUID?) throws -> MealRow {
        try validate()
        let product: Product
        switch source {
        case .product(let value): product = value
        case .recipe:
            let choices = candidates(stocks)
            let selected = selectedBatch ?? (choices.count == 1 ? choices[0].id : nil)
            guard let stock = choices.first(where: { $0.id == selected }) else {
                throw FoodError.database("Выберите приготовленную партию: «\(name)».")
            }
            product = stock.product
        }
        return MealRow(food: product.name, quantity: quantity, unit: unit, product: product,
                       batchPortions: recipeID == nil ? nil : try Numbers.parse(portions, positive: true))
    }
}
struct FoodCombination: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var note = ""
    var components: [CombinationComponent] = []
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 300,
              !components.isEmpty, Set(components.map(\.id)).count == components.count else {
            throw FoodError.database("Укажите название и добавьте компоненты сочетания.")
        }
        try components.forEach { try $0.validate() }
    }
    func rows(stocks: [BatchStock], selections: [UUID: UUID]) throws -> [MealRow] {
        try validate()
        return try components.map { try $0.row(stocks: stocks, selectedBatch: selections[$0.id]) }
    }
    static func from(rows: [MealRow], stocks: [BatchStock]) throws -> Self {
        var value = Self()
        guard !rows.isEmpty else { throw FoodError.database("Сначала добавьте продукты.") }
        for row in rows {
            guard let product = row.product, let amount = row.amount, let unit = row.unit,
                  unit == .g || unit == .kg || unit == .ml || unit == .l else {
                throw FoodError.database("Для «\(row.displayName)» сначала выберите продукт и укажите количество.")
            }
            let source: CombinationComponent.Source
            if let batchID = product.preparedBatchID {
                guard let stock = stocks.first(where: { $0.id == batchID }) else { throw FoodError.database("Не найден рецепт: «\(row.displayName)».") }
                source = .recipe(id: stock.batch.recipe.id, name: stock.batch.recipe.name)
            } else { source = .product(product) }
            let normalized = amount * ((unit == .kg || unit == .l) ? 1000 : 1)
            let component = CombinationComponent(source: source, quantity: Numbers.string(normalized), portions: Numbers.string(row.batchPortions ?? 1))
            guard component.unit.basis == unit.basis else { throw FoodError.unknownBasis }
            try component.validate()
            value.components.append(component)
        }
        return value
    }
}
struct CombinationDraft: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var editingID: UUID?
    var value: FoodCombination
}
enum PersonalSchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }
    static var models: [any PersistentModel.Type] { PersonalSchemaV6.models + [CombinationRecord.self] }
    @Model final class CombinationRecord {
        @Attribute(.unique) var id: UUID
        var data: Data
        init(_ value: FoodCombination) throws { id = value.id; data = try JSONEncoder().encode(value) }
    }
}
@MainActor final class CombinationRepository {
    private let db: ModelContext
    private(set) var readIssues: [StoredDataIssue] = []
    init(container: ModelContainer) { db = ModelContext(container); db.autosaveEnabled = false }
    func all() throws -> [FoodCombination] {
        readIssues = []
        var values: [FoodCombination] = []
        for record in try db.fetch(FetchDescriptor<PersonalSchemaV7.CombinationRecord>()) {
            do { values.append(try JSONDecoder().decode(FoodCombination.self, from: record.data)) }
            catch { readIssues.append(.init(id: record.id.uuidString, message: "Сочетание не прочитано. Исходные данные сохранены.")) }
        }
        return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func drafts() throws -> DraftCollection<CombinationDraft> { try DraftStorage.all(CombinationDraft.self, kind: .combination, db: db) }
    func begin(_ value: FoodCombination) throws -> CombinationDraft {
        let existing = try all().contains { $0.id == value.id }
        if existing, let draft = try drafts().values.first(where: { $0.editingID == value.id }) { return draft }
        let draft = CombinationDraft(editingID: existing ? value.id : nil, value: value)
        try saveDraft(draft)
        return draft
    }
    func saveDraft(_ draft: CombinationDraft) throws {
        do {
            try DraftStorage.save(draft, id: draft.id, kind: .combination, editingKey: draft.editingID?.uuidString, db: db)
            try db.save()
        } catch { db.rollback(); throw error }
    }
    func discardDraft(_ id: UUID) throws {
        do { try DraftStorage.close(id, kind: .combination, db: db); try db.save() }
        catch { db.rollback(); throw error }
    }
    func save(_ draft: CombinationDraft) throws {
        if try DraftStorage.completed(draft, id: draft.id, kind: .combination, db: db) { return }
        try save(draft.value, closing: draft.id, receipt: draft)
    }
    func save(_ value: FoodCombination) throws { try save(value, closing: nil) }
    private func save(_ value: FoodCombination, closing draftID: UUID?, receipt: CombinationDraft? = nil) throws {
        try value.validate()
        let id = value.id
        do {
            if let old = try db.fetch(FetchDescriptor<PersonalSchemaV7.CombinationRecord>(predicate: #Predicate { $0.id == id })).first {
                old.data = try JSONEncoder().encode(value)
            } else { db.insert(try PersonalSchemaV7.CombinationRecord(value)) }
            db.insert(try PersonalSchemaV5.BatchEvent(["action": "save-combination", "combinationID": id.uuidString,
                "snapshot": String(decoding: try JSONEncoder().encode(value), as: UTF8.self)]))
            if let receipt, let draftID { try DraftStorage.finish(receipt, id: draftID, kind: .combination, db: db) }
            try db.save()
        } catch { db.rollback(); throw error }
    }
    func delete(_ value: FoodCombination) throws {
        let id = value.id
        do {
            try db.fetch(FetchDescriptor<PersonalSchemaV7.CombinationRecord>(predicate: #Predicate { $0.id == id })).forEach { db.delete($0) }
            db.insert(try PersonalSchemaV5.BatchEvent(["action": "delete-combination", "combinationID": id.uuidString]))
            try db.save()
        } catch { db.rollback(); throw error }
    }
}
