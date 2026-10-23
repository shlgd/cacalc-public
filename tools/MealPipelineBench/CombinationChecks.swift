import Foundation
import SwiftData

@MainActor func checkCombinations() async throws {
    func check(_ value: Bool, _ message: String) { if !value { FileHandle.standardError.write(Data(("CHECK FAILED: " + message + "\n").utf8)); fatalError(message) } }
    func rejects(_ run: () throws -> Void) { do { try run(); preconditionFailure("Expected rejection") } catch {} }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("combinations.store")
    let rice = Product(id: "synthetic-rice", name: "Рис", brand: "Тест", basis: .g,
        calories: 300, protein: 10, fat: 2, carbs: 65, source: "synthetic-test")
    let tuna = Product(id: "synthetic-tuna", name: "Тунец", brand: "", basis: .g,
        calories: 120, protein: 25, fat: 1, carbs: 0, source: "synthetic-test")
    let recipe = RecipeTemplate(name: "Готовый рис", ingredients: [RecipeIngredient(product: rice, actual: "100")])
    let original = try PreparedBatch.make(recipe: recipe, yieldGrams: 300, portions: 3)
    let measure = BodyMeasurement(kind: .weight, value: 80, measuredAt: Date())
    let seed = Data("untouched meal draft".utf8)
    do {
        let schema = Schema(versionedSchema: PersonalSchemaV6.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let db = ModelContext(container)
        db.insert(try PersonalSchemaV5.RecipeRecord(recipe))
        db.insert(try PersonalSchemaV5.BatchRecord(original))
        db.insert(try PersonalSchemaV6.MeasurementRecord(measure))
        db.insert(PersonalSchemaV3.MealDraftRecord(seed))
        try db.save()
    }
    let container = try DiaryStore.makeContainer(url: url)
    let db = ModelContext(container)
    check(try MeasurementRepository(container: container).all() == [measure], "v6→v7 preserves measurements")
    check(try db.fetch(FetchDescriptor<PersonalSchemaV3.MealDraftRecord>())[0].data == seed, "v6→v7 preserves draft bytes")
    try db.fetch(FetchDescriptor<PersonalSchemaV3.MealDraftRecord>()).forEach { db.delete($0) }; try db.save()
    let prep = PreparedRepository(container: container)
    let repo = CombinationRepository(container: container)
    var combo = FoodCombination(name: "Рис с тунцом", components: [
        CombinationComponent(source: .recipe(id: recipe.id, name: recipe.name), quantity: "150"),
        CombinationComponent(source: .product(tuna), quantity: "80")])
    try repo.save(combo)
    check(try prep.stocks()[0].grams == 300, "saving composition never consumes stock")
    check(try CombinationRepository(container: DiaryStore.makeContainer(url: url)).all() == [combo], "combination survives reopen")
    var rows = try combo.rows(stocks: prep.stocks(), selections: [:])
    check(rows[0].amount == 150 && rows[0].batchPortions == 1, "150 grams independent from default one portion")
    check(rows[0].portion.calories == 150 && rows[1].portion.calories == 96, "nutrition uses selected batch and product")
    let journal = MealRepository(container: container)
    let draft = MealDraft(day: Day(Date()), meal: .dinner, rows: rows)
    try await journal.commit(draft); try await journal.commit(draft)
    check(try prep.stocks()[0].grams == 150 && prep.stocks()[0].portions == 2, "idempotent diary commit consumes once")
    combo.components[0].quantity = "90"; combo.components[0].portions = "0.5"
    try repo.save(combo)
    check(try prep.stocks()[0].grams == 150, "editing template never changes past diary")
    rows[0].quantity = "120"; rows[0].batchPortions = 2
    try await journal.commit(MealDraft(day: draft.day, meal: .dinner, rows: rows))
    check(try prep.stocks()[0].grams == 180 && prep.stocks()[0].portions == 1, "editing diary replaces grams and portions")
    try await journal.remove(rows[0].id)
    check(try prep.stocks()[0].grams == 300 && prep.stocks()[0].portions == 3, "delete restores chosen batch")
    var secondRecipe = recipe; secondRecipe.ingredients[0].actual = "120"
    try prep.create(CookingState(recipe: secondRecipe, yieldText: "300", portionText: "3"))
    let stocks = try prep.stocks()
    let second = stocks.first { $0.id != original.id }!
    rejects { _ = try combo.rows(stocks: stocks, selections: [:]) }
    let selected = try combo.rows(stocks: stocks, selections: [combo.components[0].id: second.id])
    check(selected[0].portion.calories == 108, "different batch of same recipe uses its own nutrition")
    check(selected[0].batchPortions == Decimal(string: "0.5"), "fractional portions preserved")
    let captured = try FoodCombination.from(rows: selected, stocks: stocks)
    check(captured.components[0].recipeID == recipe.id, "save from meal references recipe, never ephemeral batch")
    check(captured.components[0].quantity == "90", "save from meal retains grams")
    try prep.close(second.batch)
    rejects { _ = try combo.rows(stocks: prep.stocks(), selections: [combo.components[0].id: second.id]) }
    try prep.close(original)
    rejects { _ = try combo.rows(stocks: prep.stocks(), selections: [:]) }
    // A new batch unblocks the SAME saved reference; no automatic replacement with raw rice.
    try prep.create(CookingState(recipe: recipe, yieldText: "600", portionText: "4"))
    let newRows = try combo.rows(stocks: prep.stocks(), selections: [:])
    check(newRows[0].portion.calories == 45, "new cooked yield determines nutrition on reuse")
    var unknown = tuna; unknown.protein = nil
    var unknownCombo = combo
    unknownCombo.components[1].source = .product(unknown)
    check(try unknownCombo.rows(stocks: prep.stocks(), selections: [:])[1].portion.protein == nil, "unknown nutrition never becomes zero")
    var invalid = combo; invalid.components[0].quantity = "0"
    rejects { try repo.save(invalid) }
    invalid = combo; invalid.components[0].portions = "0"
    rejects { try repo.save(invalid) }
    invalid = combo; invalid.components[0].source = .product(original.product)
    rejects { try repo.save(invalid) }
    rejects { _ = try FoodCombination.from(rows: [MealRow(food: "unknown")], stocks: stocks) }
    // Two recipe components (including repeated recipe) resolve to separate rows and roll back together.
    var double = combo; double.components.append(CombinationComponent(source: combo.components[0].source, quantity: "50"))
    let doubleRows = try double.rows(stocks: prep.stocks(), selections: [:])
    let before = try prep.stocks().first { $0.active }!
    await journal.injectSaveFailure()
    do { try await journal.commit(MealDraft(day: draft.day, meal: .dinner, rows: doubleRows)); preconditionFailure("Expected save failure") } catch {}
    check(try prep.stocks().first { $0.active }!.grams == before.grams, "multi-component failed save rolls back all stock")
    try await journal.commit(MealDraft(day: draft.day, meal: .dinner, rows: doubleRows))
    let after = try prep.stocks().first { $0.id == before.id }!
    check(after.grams == before.grams - 140 && after.portions == before.portions - Decimal(string: "1.5")!, "multiple components consume summed grams and independent portions")
    let store = DiaryStore(container: container, catalog: Catalog(url: nil))
    let session = MealSession(store: store)
    await session.load()
    let fresh = try combo.rows(stocks: prep.stocks(), selections: [:])
    try await session.addCombination(fresh, combinationID: combo.id, owner: nil)
    let owner = session.draft!.id
    check(session.draft!.rows.count == 2, "session appends full composition")
    do { try await session.addCombination(fresh, combinationID: combo.id, owner: owner); preconditionFailure("Duplicate append") } catch {}
    check(session.draft!.rows.count == 2, "double tap cannot duplicate same resolved rows")
    let reopened = MealSession(store: store); await reopened.load()
    check(reopened.draft?.rows.map(\.id) == fresh.map(\.id), "composition persists in recoverable meal draft")
    do { try await session.addCombination(try combo.rows(stocks: prep.stocks(), selections: [:]), combinationID: combo.id, owner: UUID()); preconditionFailure("Stale owner") } catch {}
    try repo.delete(combo)
    check(try repo.all().isEmpty && prep.stocks().first { $0.id == before.id }!.grams == after.grams, "deleting combination preserves stock and diary")
    print("Combinations: migration, persistence, batch resolution, independent grams/portions, atomic/idempotent journal and session recovery passed")
}
