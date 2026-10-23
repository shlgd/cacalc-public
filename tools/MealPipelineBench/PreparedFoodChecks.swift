import Foundation
import SwiftData
import SQLite3

// Synthetic ingredients only. Exercises the actual disk store and journal transaction.
@MainActor func checkPreparedFood() async throws {
    func check(_ value: Bool, _ reason: String) { if !value { FileHandle.standardError.write(Data(("CHECK FAILED: " + reason + "\n").utf8)); fatalError(reason) } }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // Optional real-store migration uses a disposable COPY, never the supplied backup itself.
    if let source = ProcessInfo.processInfo.environment["CACALC_MIGRATION_COPY"] {
        let copy = folder.appendingPathComponent("real-copy.store")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        func payloads() -> [String: [Data]] {
            var db: OpaquePointer?; precondition(sqlite3_open(copy.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            var result: [String: [Data]] = [:]
            for table in ["ZJOURNALRECORD", "ZPERSONALPRODUCT", "ZGOALRECORD", "ZMEALDRAFTRECORD", "ZDRAFTRECORD", "ZPRODUCTDRAFTRECORD", "ZBATCHRECORD", "ZRECIPERECORD"] {
                var stmt: OpaquePointer?
                precondition(sqlite3_prepare_v2(db, "SELECT ZDATA FROM " + table + " ORDER BY Z_PK", -1, &stmt, nil) == SQLITE_OK)
                var rows: [Data] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rows.append(Data(bytes: sqlite3_column_blob(stmt, 0)!, count: Int(sqlite3_column_bytes(stmt, 0))))
                }
                sqlite3_finalize(stmt); result[table] = rows
            }
            return result
        }
        let before = payloads()
        let migrated = try DiaryStore.makeContainer(url: copy)
        _ = try ModelContext(migrated).fetch(FetchDescriptor<PersonalSchemaV5.BatchRecord>())
        _ = try PreparedRepository(container: migrated).stocks()
        _ = try PreparedRepository(container: migrated).recipes()
        check(payloads() == before, "real-store migration preserves all existing payload bytes")
        print("Real-store COPY → current schema: journal, products, goals and all draft payloads preserved")
    }
    let url = folder.appendingPathComponent("prepared.store")
    let seed = Data("preserve existing draft and goal".utf8)
    do {
        let schema = Schema(versionedSchema: PersonalSchemaV4.self)
        let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let db = ModelContext(old)
        db.insert(PersonalSchemaV3.MealDraftRecord(seed))
        try db.save()
    }
    let container = try DiaryStore.makeContainer(url: url)
    check(try ModelContext(container).fetch(FetchDescriptor<PersonalSchemaV3.MealDraftRecord>()).first?.data == seed, "v4 draft survives v5 migration")
    let prep = PreparedRepository(container: container)
    let lentil = Product(id: "synthetic-lentil", name: "Чечевица", brand: "", basis: .g,
        calories: 300, protein: 20, fat: 2, carbs: 50, source: "synthetic-test")
    let oil = Product(id: "synthetic-oil", name: "Масло", brand: "", basis: .g,
        calories: 900, protein: 0, fat: 100, carbs: 0, source: "synthetic-test")
    var state = CookingState(recipe: RecipeTemplate(name: "Моя чечевица", ingredients: [
        RecipeIngredient(product: lentil, planned: "250", actual: "250"),
        RecipeIngredient(product: oil, planned: "20", actual: "10")]), yieldText: "840", portionText: "4")
    try prep.saveDraft(state)
    check(try PreparedRepository(container: container).draft() == state, "preparation draft survives context recreation")
    try prep.create(state)
    check(try prep.draft() == nil, "successful preparation removes draft")
    let batch = try prep.stocks()[0].batch
    check(batch.total.calories == 840 && batch.product.calories == 100, "actual ingredients and cooked yield determine energy")
    check(try prep.recipes()[0].ingredients[1].planned == "20", "plan is separate from actual oil")
    var unknown = state.recipe
    unknown.ingredients[0].product.protein = nil
    let partial = try PreparedBatch.make(recipe: unknown, yieldGrams: 840, portions: 4)
    check(partial.total.protein == nil && partial.total.calories == 840, "missing nutrient remains unknown")
    state.recipe.ingredients[1].actual = "30"
    state.draftID = UUID()
    try prep.create(state)
    check(try prep.recipes()[0].ingredients[1].planned == "20", "repeat does not overwrite template")
    check(try prep.stocks().first { $0.id == batch.id }?.batch.total.calories == 840, "repeat cannot change previous batch")
    state.updateTemplate = true
    state.draftID = UUID()
    try prep.create(state)
    check(try prep.recipes()[0].ingredients[1].planned == "30", "explicit template update uses actual amounts")
    let repo = MealRepository(container: container)
    var row = MealRow(food: batch.name, quantity: "240", unit: .g, product: batch.product)
    var draft = MealDraft(day: Day(Date()), meal: .lunch, rows: [row])
    func stock() throws -> BatchStock { try PreparedRepository(container: container).stocks().first { $0.id == batch.id }! }
    try await repo.commit(draft)
    check(try stock().grams == 600 && stock().portions == 3, "save consumes actual grams and one portion")
    try await repo.commit(draft)
    check(try stock().grams == 600 && stock().portions == 3, "retry does not double consume")
    row.quantity = "200"; draft.rows = [row]; draft.id = UUID(); draft.editingEntryID = row.id
    try await repo.commit(draft)
    check(try stock().grams == 640 && stock().portions == 3, "editing weight replaces movement")
    await repo.injectSaveFailure()
    draft.id = UUID()
    draft.rows[0].quantity = "300"
    do { try await repo.commit(draft); preconditionFailure("failure expected") } catch {}
    check(try stock().grams == 640, "failed journal save rolls back stock")
    try await repo.remove(row.id)
    check(try stock().grams == 840 && stock().portions == 4, "deletion restores stock")
    // Planning preserves stock; consumption is atomic and idempotent.
    var plan = MealDraft(day: Day(Date()).offset(1), meal: .dinner, rows: [MealRow(food: batch.name, quantity: "100", unit: .g, product: batch.product)])
    plan.timing = MealTiming(mode: .planned, selectedAt: plan.day.date)
    try await repo.commit(plan)
    check(try stock().grams == 840 && stock().portions == 4, "plan does not consume batch")
    await repo.injectSaveFailure()
    do { try await repo.consumeEpisode(plan.timing!.episodeID); preconditionFailure("expected consumption failure") } catch {}
    check(try stock().grams == 840, "failed plan consumption rolls back stock")
    try await repo.consumeEpisode(plan.timing!.episodeID)
    try await repo.consumeEpisode(plan.timing!.episodeID)
    check(try stock().grams == 740 && stock().portions == 3, "plan consumption deducts exactly once")
    try await repo.remove(plan.rows[0].id)
    check(try stock().grams == 840 && stock().portions == 4, "deleting consumed plan restores stock")
    draft.rows = (0..<4).map { _ in MealRow(food: batch.name, quantity: "150", unit: .g, product: batch.product) }
    draft.id = UUID(); draft.editingEntryID = nil
    try await repo.commit(draft)
    check(try !stock().active && stock().grams == 240, "last portion archives with harmless gram discrepancy")
    let active = try await ProductRepository(container: container).activePreparedProducts()
    check(!active.contains { $0.preparedBatchID == batch.id }, "exhausted batch leaves search")
    try await repo.remove(draft.rows[0].id)
    check(try stock().active && stock().grams == 390 && stock().portions == 1, "deleting final serving reopens batch")
    try prep.adjust(batch.id, grams: 350, portions: 2)
    check(try stock().grams == 350 && stock().portions == 2, "explicit stock correction")
    try prep.close(try stock().batch)
    try await repo.remove(draft.rows[1].id)
    check(try !stock().active, "manual closure stays closed on diary deletion")
    let other = try prep.stocks().first { $0.id != batch.id }!.batch
    var switchRow = draft.rows[2]
    switchRow.product = other.product
    try await repo.commit(MealDraft(day: Day(Date()), meal: .lunch, rows: [switchRow]))
    check(try stock().grams == 650, "switching batch returns previous movement")
    var partialRow = MealRow(food: other.name, product: other.product)
    try await repo.commit(MealDraft(day: Day(Date()), meal: .lunch, rows: [partialRow]))
    let uses = try ModelContext(container).fetch(FetchDescriptor<PersonalSchemaV5.BatchUse>())
    check(!uses.contains { $0.rowID == partialRow.id }, "no grams means no invented portion or stock deduction")
    partialRow.quantity = "0.1"; partialRow.unit = .kg; partialRow.batchPortions = Decimal(string: "0.5")
    try await repo.commit(MealDraft(day: Day(Date()), meal: .lunch, rows: [partialRow]))
    let half = try ModelContext(container).fetch(FetchDescriptor<PersonalSchemaV5.BatchUse>()).first { $0.rowID == partialRow.id }!
    check(half.grams == "100" && half.portions == "0.5", "kg and half portion preserve actual amounts")
    let index = SearchIndex(products: [lentil, other.product])
    check(index.rank("моя чечевица", history: []).first?.product.id == other.product.id, "prepared dish is searchable by its name")
    let store = DiaryStore(container: container, catalog: Catalog(url: nil))
    try store.persistDraft(FoodDraft(day: Day(Date()), meal: .dinner, product: other.product, quantity: "100", basis: .g))
    try store.commitDraft()
    let legacy = try ModelContext(container).fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>()).first { $0.mealKey == Meal.dinner.rawValue }!
    let beforeLegacyDelete = try PreparedRepository(container: container).stocks().first { $0.id == other.id }!.grams
    try store.remove(legacy.id)
    check(try PreparedRepository(container: container).stocks().first { $0.id == other.id }!.grams == beforeLegacyDelete + 100, "legacy save and delete also adjust stock")
    let reopened = try DiaryStore.makeContainer(url: url)
    check(try PreparedRepository(container: reopened).stocks().first { $0.id == batch.id }?.grams == 650, "stock survives database reopen")
    let events = try ModelContext(reopened).fetch(FetchDescriptor<PersonalSchemaV5.BatchEvent>())
    check(events.count > 8, "movement audit saved")
    var templateState = CookingState(templateOnly: true,
        recipe: RecipeTemplate(name: "Только рецепт", ingredients: [RecipeIngredient(product: lentil, actual: "120")]))
    let countBeforeRecipe = try prep.stocks().count
    try prep.saveDraft(templateState)
    check(try prep.draft()?.templateOnly == true, "recipe-only draft remembers its mode")
    try prep.saveRecipe(templateState)
    check(try prep.stocks().count == countBeforeRecipe && prep.draft() == nil, "saving recipe creates no cooked stock")
    check(try prep.recipes().first { $0.id == templateState.recipe.id }?.ingredients[0].planned == "120", "standalone recipe saves planned amount")
    templateState.recipe.ingredients[0].actual = "140"
    templateState.draftID = UUID() // A new editing process, after the previous draft was committed.
    try prep.saveRecipe(templateState)
    check(try prep.recipes().filter { $0.id == templateState.recipe.id }.count == 1, "editing template keeps its identity")
    check(try prep.stocks().count == countBeforeRecipe, "template edit leaves existing batches alone")
    let ingredientID = templateState.recipe.ingredients[0].id
    templateState.recipe.note = "Обжарить\nЗатем добавить воду"
    templateState.draftID = UUID()
    let sameUnit = try templateState.recipe.replaceIngredient(ingredientID, with: oil)
    check(!sameUnit && templateState.recipe.ingredients[0].actual == "140", "replacement preserves grams and ingredient identity")
    check(templateState.recipe.ingredients[0].id == ingredientID, "replacement keeps ingredient UUID")
    try prep.saveRecipe(templateState)
    let savedRecipe = try prep.recipes().first { $0.id == templateState.recipe.id }!
    check(savedRecipe.note == "Обжарить\nЗатем добавить воду", "multiline note survives persistence")
    let milkML = Product(id: "synthetic-milk-ml", name: "Молоко", brand: "", basis: .ml, source: "synthetic-test")
    let differentUnit = try templateState.recipe.replaceIngredient(ingredientID, with: milkML)
    check(differentUnit && templateState.recipe.ingredients[0].actual.isEmpty && templateState.recipe.ingredients[0].planned.isEmpty, "replacement never converts g into ml")
    var noted = state
    noted.draftID = UUID() // Another cooking of the same recipe is independent.
    noted.recipe.note = "Заметка сегодняшнего приготовления"
    noted.updateTemplate = false
    noted.recipe.ingredients.reverse()
    try prep.saveDraft(noted)
    check(try prep.draft()?.recipe.ingredients.map(\.id) == noted.recipe.ingredients.map(\.id), "reordered ingredients survive draft reload")
    try prep.create(noted)
    check(try prep.stocks().first?.batch.recipe.note == noted.recipe.note, "batch keeps actual note")
    check(try prep.recipes().first { $0.id == noted.recipe.id }?.note == nil, "batch note never silently changes recipe")
    var legacyRecipe = try JSONSerialization.jsonObject(with: JSONEncoder().encode(savedRecipe)) as! [String: Any]
    legacyRecipe.removeValue(forKey: "note")
    let oldRecipe = try JSONDecoder().decode(RecipeTemplate.self, from: JSONSerialization.data(withJSONObject: legacyRecipe))
    check(oldRecipe.note == nil, "old recipes without notes still decode")
    // Discard is a durable fact, not consumed food or physical deletion.
    let discardStock = try prep.stocks().first { $0.id == other.id }!
    check(discardStock.active && discardStock.usedGrams > 0, "discard fixture includes previously consumed food")
    let discardID = discardStock.id
    let snapshotBefore = discardStock.batch
    let auditDB = ModelContext(container)
    func auditCount() throws -> Int { try ModelContext(container).fetchCount(FetchDescriptor<PersonalSchemaV5.BatchEvent>()) }
    func currentDiscardStock() throws -> BatchStock {
        try PreparedRepository(container: container).stocks().first { $0.id == discardID }!
    }
    let journalBefore = try auditDB.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>()).map(\.data)
    let recipeBefore = try prep.recipes()
    let eventsBefore = try auditCount()
    let discardDate = Date(timeIntervalSinceReferenceDate: 810_000_000)
    prep.injectDiscardSaveFailure()
    do { try prep.discard(discardID, reason: .spoiled, at: discardDate); preconditionFailure("discard failure expected") } catch {}
    check(try currentDiscardStock().batch == snapshotBefore && auditCount() == eventsBefore, "failed discard rolls back both batch and event")
    check(try prep.discard(discardID, reason: .spoiled, at: discardDate), "first discard commits")
    check(try !prep.discard(discardID, reason: .other), "duplicate discard is idempotent and retains original reason")
    check(try auditCount() == eventsBefore + 1, "one discard produces one durable event")
    let discarded = try currentDiscardStock()
    check(!discarded.active && discarded.batch.discard?.date == discardDate, "discarded stock hidden and timestamp preserved")
    check(discarded.batch.discard?.grams == discardStock.grams && discarded.batch.discard?.portions == discardStock.portions, "exact remaining amounts saved")
    check(discarded.batch.total == snapshotBefore.total && discarded.batch.recipe == snapshotBefore.recipe, "nutrients and ingredient snapshot preserved")
    check(try prep.recipes() == recipeBefore, "discard does not delete recipe")
    check(try ModelContext(container).fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>()).map(\.data) == journalBefore, "discard never rewrites diary")
    check(try await ProductRepository(container: container).activePreparedProducts().allSatisfy { $0.preparedBatchID != discardID }, "discarded stock removed from actual search source")
    do { try prep.adjust(discardID, grams: 100, portions: 1); preconditionFailure("cannot restore discarded stock by correction") } catch {}
    try prep.close(snapshotBefore) // stale UI must not erase discard metadata.
    check(try currentDiscardStock().batch == discarded.batch, "stale close cannot erase discard")
    let staleRow = MealRow(food: snapshotBefore.name, quantity: "10", unit: .g, product: snapshotBefore.product)
    do { try await repo.commit(MealDraft(day: Day(Date()), meal: .lunch, rows: [staleRow])); preconditionFailure("stale selection cannot consume discarded stock") } catch {}
    let reopenedDiscard = try DiaryStore.makeContainer(url: url)
    check(try PreparedRepository(container: reopenedDiscard).stocks().first { $0.id == discardID }?.batch == discarded.batch, "discard survives database reopening")
    let savedEvents = try ModelContext(reopenedDiscard).fetch(FetchDescriptor<PersonalSchemaV5.BatchEvent>())
    let discardedEvents = try savedEvents.filter { try JSONDecoder().decode([String: String].self, from: $0.payload)["action"] == "discard" }
    check(discardedEvents.count == 1 && discardedEvents[0].date == discardDate, "discard audit persists exact timestamp")
    let audit = try JSONDecoder().decode([String: String].self, from: discardedEvents[0].payload)
    check(audit["reason"] == "spoiled" && audit["grams"] == Numbers.string(discardStock.grams) && audit["beforeSnapshot"] != nil && audit["snapshot"] != nil, "audit retains reason, amount and before/after snapshots")
    try await repo.remove(partialRow.id)
    check(try !currentDiscardStock().active && currentDiscardStock().batch.discard == discarded.batch.discard, "diary deletion cannot reactivate discarded stock or change discarded amount")
    var oldBatchJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshotBefore)) as! [String: Any]
    oldBatchJSON.removeValue(forKey: "discard")
    let oldBatch = try JSONDecoder().decode(PreparedBatch.self, from: JSONSerialization.data(withJSONObject: oldBatchJSON))
    check(oldBatch.discard == nil && oldBatch == snapshotBefore, "old JSON without discard decodes unchanged")
    var dated = snapshotBefore
    dated.created = discardDate
    check(dated.ageLabel(at: discardDate.addingTimeInterval(-60)) == "Приготовлено меньше часа назад", "future timestamps never show negative age")
    check(dated.ageLabel(at: discardDate.addingTimeInterval(3599)) == "Приготовлено меньше часа назад", "age floors hours")
    check(dated.ageLabel(at: discardDate.addingTimeInterval(3600)) == "Приготовлено 1 ч. назад", "first hour")
    check(dated.ageLabel(at: discardDate.addingTimeInterval(86400)) == "Приготовлено 1 дн. 0 ч. назад", "full day boundary")
    check(dated.ageLabel(at: discardDate.addingTimeInterval(190800)) == "Приготовлено 2 дн. 5 ч. назад", "elapsed days and hours")
    print("Prepared food: migration, snapshots, stock lifecycle, age, discard audit, retry, search exclusion and atomic rollback passed")
}
