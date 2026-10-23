import Foundation
import SwiftData

struct RecipeIngredient: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var product: Product
    var planned = ""
    var actual = ""
}
struct RecipeTemplate: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var ingredients: [RecipeIngredient] = []
    var note: String?
    @discardableResult mutating func replaceIngredient(_ id: UUID, with product: Product) throws -> Bool {
        guard product.preparedBatchID == nil, product.basis == .g || product.basis == .ml else { throw FoodError.unknownBasis }
        guard let index = ingredients.firstIndex(where: { $0.id == id }) else { throw FoodError.database("Ингредиент уже удалён.") }
        let changedUnit = ingredients[index].product.basis != product.basis
        ingredients[index].product = product
        if changedUnit { ingredients[index].actual = ""; ingredients[index].planned = "" }
        return changedUnit
    }
}
struct PreparedBatch: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var recipe: RecipeTemplate
    var created = Date()
    var yieldGrams: Decimal
    var portions: Decimal
    var closed = false
    var discard: BatchDiscard?
    var gramAdjustment: Decimal?
    var portionAdjustment: Decimal?
    var total: PortionSnapshot
    var name: String { recipe.name }
    func ageLabel(at now: Date) -> String {
        let hours = Int(max(0, now.timeIntervalSince(created)) / 3600)
        if hours == 0 { return "Приготовлено меньше часа назад" }
        if hours < 24 { return "Приготовлено \(hours) ч. назад" }
        return "Приготовлено \(hours / 24) дн. \(hours % 24) ч. назад"
    }
    var product: Product {
        Product(id: "prepared:" + id.uuidString, name: name, brand: "", basis: .g,
                calories: total.calories.map { $0 * 100 / yieldGrams },
                protein: total.protein.map { $0 * 100 / yieldGrams },
                fat: total.fat.map { $0 * 100 / yieldGrams },
                carbs: total.carbs.map { $0 * 100 / yieldGrams },
                source: "prepared-batch", preparedBatchID: id)
    }
    static func make(recipe: RecipeTemplate, yieldGrams: Decimal, portions: Decimal) throws -> Self {
        guard !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !recipe.ingredients.isEmpty, yieldGrams > 0, yieldGrams <= 1_000_000,
              portions > 0, portions <= 1000 else { throw FoodError.database("Укажите название, ингредиенты, итоговый вес и число порций.") }
        var values: [PortionSnapshot] = []
        for ingredient in recipe.ingredients {
            guard ingredient.product.preparedBatchID == nil else { throw FoodError.database("Вложенные блюда пока не поддерживаются.") }
            let amount = try Numbers.parse(ingredient.actual, positive: false)
            guard amount >= 0 else { throw FoodError.invalidNumber }
            if amount == 0 { continue }
            guard let unit = FoodUnit(rawValue: ingredient.product.basis.rawValue) else { throw FoodError.unknownBasis }
            values.append(PortionSnapshot(product: ingredient.product, amount: amount, unit: unit))
        }
        guard !values.isEmpty else { throw FoodError.database("Добавьте хотя бы один ингредиент с количеством больше нуля.") }
        let sum = NutritionSummary(values)
        let total = PortionSnapshot(calories: sum.missingCalories == 0 ? sum.known.calories : nil,
                                    protein: sum.missingProtein == 0 ? sum.known.protein : nil,
                                    fat: sum.missingFat == 0 ? sum.known.fat : nil,
                                    carbs: sum.missingCarbs == 0 ? sum.known.carbs : nil)
        return Self(recipe: recipe, yieldGrams: yieldGrams, portions: portions, total: total)
    }
}
struct BatchDiscard: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        case spoiled, other
        var title: String { self == .spoiled ? "Испортилось" : "Другая причина" }
    }
    var date: Date
    var reason: Reason
    var grams: Decimal
    var portions: Decimal
}
struct BatchStock: Identifiable, Sendable {
    var batch: PreparedBatch
    var usedGrams: Decimal
    var usedPortions: Decimal
    var id: UUID { batch.id }
    var grams: Decimal { max(0, batch.yieldGrams + (batch.gramAdjustment ?? 0) - usedGrams) }
    var portions: Decimal { max(0, batch.portions + (batch.portionAdjustment ?? 0) - usedPortions) }
    var active: Bool { !batch.closed && batch.discard == nil && grams > 0 && portions > 0 }
    var product: Product {
        var value = batch.product
        value.preparedNote = "Приготовлено · ≈" + Numbers.display(grams) + " г"
        return value
    }
    var nextGrams: Decimal? { active ? grams / portions : nil }
}

enum PersonalSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }
    static var models: [any PersistentModel.Type] {
        PersonalSchemaV4.models + [RecipeRecord.self, BatchRecord.self, BatchUse.self, CookingDraft.self, BatchEvent.self]
    }
    @Model final class RecipeRecord {
        @Attribute(.unique) var id: UUID
        var data: Data
        init(_ recipe: RecipeTemplate) throws { id = recipe.id; data = try JSONEncoder().encode(recipe) }
    }
    @Model final class BatchRecord {
        @Attribute(.unique) var id: UUID
        var data: Data
        init(_ batch: PreparedBatch) throws { id = batch.id; data = try JSONEncoder().encode(batch) }
    }
    @Model final class BatchUse {
        @Attribute(.unique) var rowID: UUID
        var batchID: UUID
        var grams: String
        var portions: String
        init(rowID: UUID, batchID: UUID, grams: Decimal, portions: Decimal) {
            self.rowID = rowID; self.batchID = batchID
            self.grams = NSDecimalNumber(decimal: grams).stringValue
            self.portions = NSDecimalNumber(decimal: portions).stringValue
        }
    }
    @Model final class BatchEvent {
        @Attribute(.unique) var id: UUID
        var date: Date
        var payload: Data
        init(_ fields: [String: String]) throws {
            id = UUID(); date = Date(); payload = try JSONEncoder().encode(fields)
        }
    }
    @Model final class CookingDraft {
        @Attribute(.unique) var key: String
        var data: Data
        init(_ data: Data) { key = "current"; self.data = data }
    }
}
struct CookingState: Codable, Equatable, Identifiable, Sendable {
    var draftID: UUID? = UUID()
    var id: UUID { draftID ?? recipe.id }
    var templateOnly: Bool?
    var recipe = RecipeTemplate()
    var yieldText = ""
    var portionText = "4"
    var updateTemplate = false
}

/// All journal-linked movements are written using the caller's transaction.
enum PreparedStorage {
    struct Snapshot: Sendable {
        var stocks: [BatchStock] = []
        var issues: [StoredDataIssue] = []
    }
    static func snapshot(_ db: ModelContext, uses suppliedUses: [PersonalSchemaV5.BatchUse]? = nil) throws -> Snapshot {
        let uses = try suppliedUses ?? db.fetch(FetchDescriptor<PersonalSchemaV5.BatchUse>())
        var totals: [UUID: (grams: Decimal, portions: Decimal)] = [:]
        var invalid = Set<UUID>(), result = Snapshot()
        for use in uses {
            do {
                let grams = try Numbers.parse(use.grams), portions = try Numbers.parse(use.portions, positive: true)
                guard portions <= 1000 else { throw FoodError.invalidNumber }
                let old = totals[use.batchID] ?? (0, 0)
                totals[use.batchID] = (old.grams + grams, old.portions + portions)
            } catch {
                invalid.insert(use.batchID)
                result.issues.append(.init(id: use.rowID.uuidString,
                    message: "Не удалось прочитать списание \(use.rowID) партии \(use.batchID). Остаток неизвестен; исходная запись сохранена."))
            }
        }
        for record in try db.fetch(FetchDescriptor<PersonalSchemaV5.BatchRecord>()) {
            do {
                let batch = try JSONDecoder().decode(PreparedBatch.self, from: record.data)
                guard batch.id == record.id, !batch.yieldGrams.isNaN, batch.yieldGrams > 0,
                      !batch.portions.isNaN, batch.portions > 0 else { throw FoodError.invalidNumber }
                guard !invalid.contains(record.id) else { continue }
                let used = totals[batch.id] ?? (0, 0)
                result.stocks.append(BatchStock(batch: batch, usedGrams: used.grams, usedPortions: used.portions))
            } catch {
                result.issues.append(.init(id: record.id.uuidString,
                    message: "Не удалось прочитать партию \(record.id). Исходные данные сохранены."))
            }
        }
        result.stocks.sort { $0.batch.created > $1.batch.created }
        return result
    }
    static func stocks(_ db: ModelContext) throws -> [BatchStock] {
        let value = try snapshot(db)
        guard value.issues.isEmpty else { throw FoodError.database(value.issues.map(\.message).joined(separator: "\n")) }
        return value.stocks
    }
    /// One stock/movement pass for an entire diary transaction; updates reflect prior rows.
    final class Reconciliation {
        private let db: ModelContext
        private var stocks: [UUID: BatchStock]
        private var uses: [UUID: PersonalSchemaV5.BatchUse]
        let available: Set<UUID>
        init(_ db: ModelContext) throws {
            self.db = db
            let movements = try db.fetch(FetchDescriptor<PersonalSchemaV5.BatchUse>())
            let values = try PreparedStorage.snapshot(db, uses: movements).stocks
            stocks = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
            available = Set(values.filter(\.active).map(\.id))
            uses = Dictionary(uniqueKeysWithValues: movements.map { ($0.rowID, $0) })
        }
        func remove(_ id: UUID) throws {
            guard let old = uses.removeValue(forKey: id) else { return }
            let grams = try Numbers.parse(old.grams), portions = try Numbers.parse(old.portions, positive: true)
            stocks[old.batchID]?.usedGrams -= grams; stocks[old.batchID]?.usedPortions -= portions
            db.insert(try PersonalSchemaV5.BatchEvent(["action": "return", "rowID": id.uuidString,
                "batchID": old.batchID.uuidString, "grams": old.grams, "portions": old.portions]))
            db.delete(old)
        }
        func apply(_ row: MealRow) throws {
            let previous = uses[row.id]
            guard let batchID = row.product?.preparedBatchID, let amount = row.amount else { try remove(row.id); return }
            guard row.unit == .g || row.unit == .kg, let stock = stocks[batchID] else {
                throw FoodError.database("Партия или её достоверный остаток недоступны. Укажите фактическую массу в граммах.")
            }
            guard stock.batch.discard == nil || previous?.batchID == batchID else { throw FoodError.database("Эта партия выброшена. Выберите другое блюдо.") }
            guard available.contains(batchID) || previous?.batchID == batchID else { throw FoodError.database("Эта партия уже закончилась.") }
            let portions = row.batchPortions ?? 1, grams = amount * (row.unit == .kg ? 1000 : 1)
            guard !portions.isNaN, portions > 0, portions <= 1000 else { throw FoodError.invalidNumber }
            let fields = ["action": "consume", "rowID": row.id.uuidString, "batchID": batchID.uuidString,
                "grams": Numbers.string(grams), "portions": Numbers.string(portions),
                "previousBatchID": previous?.batchID.uuidString ?? "", "previousGrams": previous?.grams ?? "",
                "previousPortions": previous?.portions ?? "", "remainingGramsBefore": Numbers.string(stock.grams),
                "remainingPortionsBefore": Numbers.string(stock.portions)]
            if let previous {
                stocks[previous.batchID]?.usedGrams -= try Numbers.parse(previous.grams)
                stocks[previous.batchID]?.usedPortions -= try Numbers.parse(previous.portions, positive: true)
                previous.batchID = batchID; previous.grams = NSDecimalNumber(decimal: grams).stringValue
                previous.portions = NSDecimalNumber(decimal: portions).stringValue
            } else {
                let use = PersonalSchemaV5.BatchUse(rowID: row.id, batchID: batchID, grams: grams, portions: portions)
                db.insert(use); uses[row.id] = use
            }
            stocks[batchID]?.usedGrams += grams; stocks[batchID]?.usedPortions += portions
            db.insert(try PersonalSchemaV5.BatchEvent(fields))
        }
    }
    static func removeUse(_ id: UUID, db: ModelContext) throws {
        for use in try db.fetch(FetchDescriptor<PersonalSchemaV5.BatchUse>(predicate: #Predicate { $0.rowID == id })) {
            _ = try Numbers.parse(use.grams); _ = try Numbers.parse(use.portions, positive: true)
            db.insert(try PersonalSchemaV5.BatchEvent(["action": "return", "rowID": id.uuidString,
                "batchID": use.batchID.uuidString, "grams": use.grams, "portions": use.portions]))
            db.delete(use)
        }
    }
    static func reconcile(_ row: MealRow, db: ModelContext, available: Set<UUID>? = nil) throws {
        let id = row.id
        let previous = try db.fetch(FetchDescriptor<PersonalSchemaV5.BatchUse>(predicate: #Predicate { $0.rowID == id })).first
        guard let batchID = row.product?.preparedBatchID, let amount = row.amount else {
            if previous != nil { try removeUse(id, db: db) }; return
        }
        guard row.unit == .g || row.unit == .kg else { throw FoodError.database("Для приготовленного блюда укажите фактическую массу в граммах.") }
        guard let stock = try stocks(db).first(where: { $0.id == batchID }) else { throw FoodError.database("Приготовленная партия не найдена.") }
        guard stock.batch.discard == nil || previous?.batchID == batchID else {
            throw FoodError.database("Эта партия выброшена. Выберите другое блюдо.")
        }
        // Existing use remains editable even after this batch was exhausted.
        guard (available?.contains(batchID) ?? stock.active) || previous?.batchID == batchID else {
            throw FoodError.database("Эта партия уже закончилась. Выберите другую или поправьте остаток.")
        }
        let portions = row.batchPortions ?? 1
        guard portions > 0, portions <= 1000 else { throw FoodError.invalidNumber }
        let grams = amount * (row.unit == .kg ? 1000 : 1)
        let fields = ["action": "consume", "rowID": id.uuidString, "batchID": batchID.uuidString,
            "grams": Numbers.string(grams), "portions": Numbers.string(portions),
            "previousBatchID": previous?.batchID.uuidString ?? "",
            "previousGrams": previous?.grams ?? "", "previousPortions": previous?.portions ?? "",
            "remainingGramsBefore": Numbers.string(stock.grams), "remainingPortionsBefore": Numbers.string(stock.portions)]
        db.insert(try PersonalSchemaV5.BatchEvent(fields))
        if let previous {
            previous.batchID = batchID
            previous.grams = NSDecimalNumber(decimal: grams).stringValue
            previous.portions = NSDecimalNumber(decimal: portions).stringValue
        } else { db.insert(PersonalSchemaV5.BatchUse(rowID: id, batchID: batchID, grams: grams, portions: portions)) }
    }
}
@MainActor final class PreparedRepository {
    private let db: ModelContext
    private var failNextDiscardSave = false
    private(set) var readIssues: [StoredDataIssue] = []
    func injectDiscardSaveFailure() { failNextDiscardSave = true }
    init(container: ModelContainer) { db = ModelContext(container); db.autosaveEnabled = false }
    func stocks() throws -> [BatchStock] { try PreparedStorage.stocks(db) }
    func recipes() throws -> [RecipeTemplate] {
        var result: [RecipeTemplate] = []; readIssues = []
        for record in try db.fetch(FetchDescriptor<PersonalSchemaV5.RecipeRecord>()) {
            do { result.append(try JSONDecoder().decode(RecipeTemplate.self, from: record.data)) }
            catch { readIssues.append(.init(id: record.id.uuidString, message: "Рецепт \(record.id) не прочитан. Исходные данные сохранены.")) }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func drafts() throws -> DraftCollection<CookingState> { try DraftStorage.all(CookingState.self, kind: .cooking, db: db) }
    func draft() throws -> CookingState? { try drafts().values.first }
    func saveDraft(_ state: CookingState) throws {
        do {
            try DraftStorage.save(state, id: state.id, kind: .cooking,
                editingKey: state.templateOnly == true ? state.recipe.id.uuidString : nil, db: db)
            try db.save()
        } catch { db.rollback(); throw error }
    }
    func discardDraft(_ id: UUID) throws {
        do { try DraftStorage.close(id, kind: .cooking, db: db); try db.save() }
        catch { db.rollback(); throw error }
    }
    func stockSnapshot() throws -> PreparedStorage.Snapshot { try PreparedStorage.snapshot(db) }
    func saveRecipe(_ state: CookingState) throws {
        if try DraftStorage.completed(state, id: state.id, kind: .cooking, db: db) { return }
        // Validate actual/planned ingredient amounts without inventing a cooked yield.
        _ = try PreparedBatch.make(recipe: state.recipe, yieldGrams: 100, portions: 1)
        var template = state.recipe
        template.ingredients = template.ingredients.map { var value = $0; value.planned = value.actual; return value }
        let id = template.id
        do {
            if let old = try db.fetch(FetchDescriptor<PersonalSchemaV5.RecipeRecord>(predicate: #Predicate { $0.id == id })).first {
                old.data = try JSONEncoder().encode(template)
            } else { db.insert(try PersonalSchemaV5.RecipeRecord(template)) }
            db.insert(try PersonalSchemaV5.BatchEvent(["action": "save-recipe", "recipeID": id.uuidString,
                "snapshot": String(decoding: try JSONEncoder().encode(template), as: UTF8.self)]))
            try DraftStorage.finish(state, id: state.id, kind: .cooking, db: db)
            try StorageRevision.touch("prepared", db: db)
            try db.save()
        } catch { db.rollback(); throw error }
    }
    func create(_ state: CookingState) throws {
        if try DraftStorage.completed(state, id: state.id, kind: .cooking, db: db) { return }
        let batch = try PreparedBatch.make(recipe: state.recipe,
            yieldGrams: Numbers.parse(state.yieldText, positive: true),
            portions: Numbers.parse(state.portionText, positive: true))
        do {
            let id = state.recipe.id
            let existing = try db.fetch(FetchDescriptor<PersonalSchemaV5.RecipeRecord>(predicate: #Predicate { $0.id == id })).first
            if existing == nil || state.updateTemplate {
                var template = state.recipe
                template.ingredients = template.ingredients.map {
                    var value = $0
                    value.planned = state.updateTemplate ? value.actual : (value.planned.isEmpty ? value.actual : value.planned)
                    value.actual = value.planned
                    return value
                }
                if let existing { existing.data = try JSONEncoder().encode(template) }
                else { db.insert(try PersonalSchemaV5.RecipeRecord(template)) }
            }
            db.insert(try PersonalSchemaV5.BatchRecord(batch))
            db.insert(try PersonalSchemaV5.BatchEvent(["action": "prepared", "batchID": batch.id.uuidString,
                "snapshot": String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)]))
            try DraftStorage.finish(state, id: state.id, kind: .cooking, db: db)
            try StorageRevision.touch("prepared", db: db)
            try db.save()
        } catch { db.rollback(); throw error }
    }
    func adjust(_ id: UUID, grams: Decimal, portions: Decimal) throws {
        guard grams >= 0, grams <= 1_000_000, portions >= 0, portions <= 1000,
              let stock = try stocks().first(where: { $0.id == id }),
              let record = try db.fetch(FetchDescriptor<PersonalSchemaV5.BatchRecord>(predicate: #Predicate { $0.id == id })).first else { throw FoodError.invalidNumber }
        var batch = stock.batch
        guard batch.discard == nil else { throw FoodError.database("Эта партия выброшена. Её историю можно посмотреть, но вернуть остаток нельзя.") }
        batch.gramAdjustment = grams + stock.usedGrams - batch.yieldGrams
        batch.portionAdjustment = portions + stock.usedPortions - batch.portions
        batch.closed = grams == 0 || portions == 0
        do {
            record.data = try JSONEncoder().encode(batch)
            db.insert(try PersonalSchemaV5.BatchEvent(["action": "adjust-stock", "batchID": id.uuidString,
                "beforeGrams": Numbers.string(stock.grams), "beforePortions": Numbers.string(stock.portions),
                "grams": Numbers.string(grams), "portions": Numbers.string(portions)]))
            try StorageRevision.touch("prepared", db: db)
            try db.save()
        } catch { db.rollback(); throw error }
    }
    func close(_ batch: PreparedBatch) throws {
        let id = batch.id
        guard let record = try db.fetch(FetchDescriptor<PersonalSchemaV5.BatchRecord>(predicate: #Predicate { $0.id == id })).first else { return }
        var value = try JSONDecoder().decode(PreparedBatch.self, from: record.data)
        guard !value.closed, value.discard == nil else { return }
        value.closed = true
        do {
            record.data = try JSONEncoder().encode(value)
            db.insert(try PersonalSchemaV5.BatchEvent(["action": "manual-close", "batchID": id.uuidString]))
            try StorageRevision.touch("prepared", db: db)
            try db.save()
        }
        catch { db.rollback(); throw error }
    }
    @discardableResult
    func discard(_ id: UUID, reason: BatchDiscard.Reason, at now: Date = Date()) throws -> Bool {
        guard let stock = try stocks().first(where: { $0.id == id }),
              let record = try db.fetch(FetchDescriptor<PersonalSchemaV5.BatchRecord>(predicate: #Predicate { $0.id == id })).first else {
            throw FoodError.database("Приготовленная партия не найдена.")
        }
        if stock.batch.discard != nil { return false }
        guard stock.active else { throw FoodError.database("Эта партия уже закончилась. Обновите список блюд.") }
        var batch = stock.batch
        batch.discard = BatchDiscard(date: now, reason: reason, grams: stock.grams, portions: stock.portions)
        batch.closed = true
        do {
            let before = String(decoding: record.data, as: UTF8.self)
            record.data = try JSONEncoder().encode(batch)
            let event = try PersonalSchemaV5.BatchEvent([
                "action": "discard", "batchID": id.uuidString, "reason": reason.rawValue,
                "grams": Numbers.string(stock.grams), "portions": Numbers.string(stock.portions),
                "usedGrams": Numbers.string(stock.usedGrams), "usedPortions": Numbers.string(stock.usedPortions),
                "beforeSnapshot": before, "snapshot": String(decoding: record.data, as: UTF8.self)
            ])
            event.date = now
            db.insert(event)
            if failNextDiscardSave {
                failNextDiscardSave = false
                throw FoodError.database("Тестовый отказ сохранения списания.")
            }
            try StorageRevision.touch("prepared", db: db)
            try db.save()
            return true
        } catch { db.rollback(); throw error }
    }
}
