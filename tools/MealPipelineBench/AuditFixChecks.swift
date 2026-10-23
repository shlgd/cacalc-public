import Foundation
import SwiftData

private actor AuditAPIGate {
    private var pending: [CheckedContinuation<(Data, HTTPURLResponse), Never>] = []
    var waiting: Int { pending.count }
    func wait() async -> (Data, HTTPURLResponse) { await withCheckedContinuation { pending.append($0) } }
    func release(_ text: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": text]]]])
        let response = HTTPURLResponse(url: URL(string: "https://synthetic.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        pending.removeFirst().resume(returning: (data, response))
    }
}

// Only synthetic fixtures, on a disposable on-disk SwiftData store.
@MainActor func checkAuditFixes() async throws {
    func check(_ value: Bool, _ message: String) { if !value { FileHandle.standardError.write(Data(("CHECK FAILED: " + message + "\n").utf8)); fatalError(message) } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cacalc-audit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("synthetic.store"), today = Day(Date())
    let product = Product(id: "synthetic-audit", name: "Яблоко", brand: "", basis: .g,
        calories: 46, protein: 1, fat: 0, carbs: 10, source: "synthetic-test")
    var p1 = ProductCreationDraft(); p1.name = "Первый"; p1.calories = "46"; p1.protein = "1"; p1.fat = "0"; p1.carbs = "10"
    p1.transcript = "синтетическая этикетка"; p1.audioFile = "synthetic-product.wav"; p1.voiceStage = .recorded
    var m1 = MealDraft(day: today, meal: .breakfast, rows: [MealRow(food: "Яблоко", quantity: "100", unit: .g, product: product)])
    m1.transcript = "яблоко сто грамм"; m1.audioFile = "synthetic-meal.wav"; m1.livePendingText = "ресторанный суп"
    m1.auditPending = [.init(name: "syntheticEvent", fields: ["eventID": UUID().uuidString])]
    m1.linkingRowID = m1.rows[0].id; m1.linkingProductID = p1.id.uuidString
    let recipe = RecipeTemplate(name: "Первый рецепт", ingredients: [RecipeIngredient(product: product, actual: "100")])
    var c1 = CookingState(recipe: recipe); c1.yieldText = "200"; c1.portionText = "2"
    var old = FoodDraft(day: today.offset(1), meal: .dinner, quantity: "125", basis: .g)
    old.custom = true; old.customName = "Старая карточка"; old.customCalories = "12,5"; old.customProtein = "1"; old.customFat = "0"; old.customCarbs = "2"
    // V7 payloads really pass through the versioned disk migration.
    do {
        let schema = Schema(versionedSchema: PersonalSchemaV7.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let db = ModelContext(container)
        db.insert(PersonalSchemaV2.ProductDraftRecord(try JSONEncoder().encode(p1)))
        db.insert(PersonalSchemaV3.MealDraftRecord(try JSONEncoder().encode(m1)))
        db.insert(PersonalSchemaV5.CookingDraft(try JSONEncoder().encode(c1)))
        db.insert(PersonalSchema.DraftRecord(try JSONEncoder().encode(old)))
        try db.save()
    }
    let container = try DiaryStore.makeContainer(url: url)
    let products = ProductRepository(container: container), meals = MealRepository(container: container)
    let prepared = PreparedRepository(container: container), combinations = CombinationRepository(container: container)
    let imported = try await meals.drafts().values
    let migratedMeal = imported.first { $0.id == m1.id }!
    check(migratedMeal.rows == m1.rows && migratedMeal.transcript == m1.transcript && migratedMeal.audioFile == m1.audioFile,
          "V7→V8 preserves meal UUID, rows and audio/transcript")
    check(migratedMeal.auditPending == m1.auditPending && migratedMeal.linkingRowID == m1.linkingRowID,
          "V7→V8 preserves pending links and diagnostic outbox")
    let migratedPlan = imported.first { $0.id != m1.id }!
    check(migratedPlan.timing?.isPlanned == true && migratedPlan.day == old.day && migratedPlan.meal == old.meal,
          "legacy future input remains a plan")
    let migratedCard = try await products.drafts().values.first { $0.id == migratedPlan.linkingProductDraftID }!
    check(migratedCard.calories == "12,5" && migratedCard.name == old.customName, "legacy card fields remain editable")
    let migratedCooking = try prepared.drafts().values.first!
    check(migratedCooking.id != recipe.id && migratedCooking.recipe == recipe, "cooking process and recipe have different IDs")
    var p2 = p1; p2.id = UUID(); p2.productID = UUID().uuidString; p2.name = "Второй"; p2.audioFile = nil
    try await products.persist(p2)
    let m2 = MealDraft(day: today.offset(-1), meal: .lunch, rows: [MealRow(food: "Без карточки")])
    try await meals.persist(m2)
    let r1 = CookingState(templateOnly: true, recipe: recipe)
    let r2 = CookingState(templateOnly: true, recipe: RecipeTemplate(name: "Второй рецепт", ingredients: recipe.ingredients))
    try prepared.saveDraft(r1); try prepared.saveDraft(r2)
    var c2 = c1; c2.draftID = UUID(); c2.recipe.note = "Другая готовка того же рецепта"
    try prepared.saveDraft(c2)
    let combination = try combinations.begin(FoodCombination(name: "Незаконченный набор"))
    let empty = MealDraft(day: today.offset(-2), meal: .dinner)
    try await meals.persist(empty)
    let reopened = try DiaryStore.makeContainer(url: url)
    let reProducts = ProductRepository(container: reopened), reMeals = MealRepository(container: reopened)
    let rePrepared = PreparedRepository(container: reopened), reCombinations = CombinationRepository(container: reopened)
    check(try await reProducts.drafts().values.count == 3, "two products plus migrated card reopen independently")
    check(try rePrepared.drafts().values.count == 4, "two recipes and two cookings of one recipe reopen")
    check(try reCombinations.drafts().values == [combination], "unfinished combination reopens")
    check(try await reMeals.drafts().values.contains(empty), "empty draft survives restart")
    _ = try await reProducts.commit(p2)
    try await reProducts.discardDraft(p1.id)
    check(try await reProducts.drafts().values.map(\.id) == [migratedCard.id], "commit/discard affect only the selected product")
    try rePrepared.saveRecipe(r1); try rePrepared.discardDraft(r2.id)
    check(try rePrepared.drafts().values.count == 2, "recipe completion leaves both cookings")
    try rePrepared.create(migratedCooking); try rePrepared.discardDraft(c2.id)
    check(try rePrepared.drafts().values.isEmpty, "independent cooking completion/discard")
    let batch = try rePrepared.stocks().first!
    check(batch.grams == 200, "created batch read through the real stock consumer")
    await reMeals.injectSaveFailure()
    do { try await reMeals.commit(m2); preconditionFailure("save must fail") } catch {}
    check(try await reMeals.drafts().values.contains(m2), "failed commit keeps exact input")
    check(try await reMeals.page(for: m2.day).items.isEmpty, "failed commit leaves no partial diary row")
    try await reMeals.commit(m2)
    try await reMeals.discardDraft(empty.id)
    check(try await reMeals.drafts().values.count == 2, "meal completion leaves other dates and legacy plan")
    do { try await reMeals.persist(m2); preconditionFailure("late autosave must not resurrect committed input") } catch {}
    check(try await reMeals.page(for: m2.day).summary.missingCalories == 1, "unknown food is retained, not zero calories")
    let store = DiaryStore(container: reopened, catalog: Catalog(url: nil))
    let session = MealSession(store: store, diagnosticLog: MatchingLog(directory: root.appendingPathComponent("log")))
    await session.repository.injectLoadFailure(); await session.load()
    check(session.error != nil, "first loading failure is shown")
    await session.load()
    check(session.drafts.count == 2, "second load retries the repository, not a failed task")
    let savedItem = try await reMeals.page(for: m2.day).items[0]
    await session.begin(day: today, item: savedItem)
    check(session.draft?.editingEntryID == savedItem.id && session.draft?.rows.first?.id == savedItem.id,
          "editing chosen row opens its own draft despite existing unfinished meals")
    await session.close()
    // Episode assignment changes all siblings in one transaction.
    let timing = MealTiming(mode: .now)
    let a = MealRow(timing: timing, food: "Первый", quantity: "100", unit: .g, product: product)
    let b = MealRow(timing: timing, food: "Второй", quantity: "50", unit: .g, product: product)
    try await reMeals.commit(MealDraft(timing: timing, day: today, meal: .breakfast, rows: [a, b]))
    let page = try await reMeals.page(for: today)
    let entry = page.items.first { $0.id == a.id }!
    var edit = MealDraft(timing: entry.row.timing, day: today, meal: .dinner, rows: [entry.row]); edit.editingEntryID = a.id
    try await reMeals.commit(edit)
    check(try await reMeals.page(for: today).items.filter { [a.id, b.id].contains($0.id) }.allSatisfy { $0.meal == .dinner }, "F06 whole episode moves")
    // Plans never enter usage memory until explicit confirmation, regardless of calendar.
    let planTiming = MealTiming(mode: .planned, selectedAt: today.date)
    let plannedProduct = Product(id: "synthetic-planned", name: "План", brand: "", basis: .g, calories: 10, protein: 0, fat: 0, carbs: 0, source: "synthetic-test")
    let planRow = MealRow(timing: planTiming, food: "План", quantity: "100", unit: .g, product: plannedProduct)
    try await reMeals.commit(MealDraft(timing: planTiming, day: today, meal: .lunch, rows: [planRow]))
    check(try await reMeals.usage().allSatisfy { $0.product.id != plannedProduct.id }, "past/today plan excluded from consumption memory")
    try await reMeals.consumeEpisode(planTiming.episodeID)
    check(try await reMeals.usage().contains { $0.product.id == plannedProduct.id }, "plan→fact invalidates usage snapshot")
    // One corrupt historical blob doesn't stop unrelated reads or writes.
    let db = ModelContext(reopened), badID = UUID(), bytes = Data("synthetic damaged JSON".utf8)
    db.insert(PersonalSchemaV3.JournalRecord(id: badID, day: today, meal: .lunch, data: bytes)); try db.save()
    let damaged = try await reMeals.page(for: today)
    check(damaged.items.contains { $0.id == badID } && damaged.summary.missingCalories == 1 && !damaged.issues.isEmpty,
          "corrupt row remains visibly incomplete beside healthy entries")
    try store.reload()
    try await reMeals.reassignMeal([a.id], to: .lunch)
    check(try ModelContext(reopened).fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>(predicate: #Predicate { $0.id == badID })).first?.data == bytes,
          "corrupt payload preserved byte for byte after unrelated episode edit")
    let badUse = PersonalSchemaV5.BatchUse(rowID: UUID(), batchID: batch.id, grams: 1, portions: 1)
    badUse.grams = "damaged"; db.insert(badUse); try db.save()
    let stockError = try rePrepared.stockSnapshot()
    check(!stockError.issues.isEmpty && stockError.stocks.allSatisfy { $0.id != batch.id }, "corrupt movement never yields confident remaining grams")
    do { _ = try rePrepared.stocks(); preconditionFailure("corrupt stock must be rejected at consumption boundary") } catch {}
    let unrelated = MealDraft(day: today, meal: .dinner, rows: [MealRow(food: "Еда без связи с повреждённой партией")])
    try await reMeals.commit(unrelated)
    check(try ModelContext(reopened).fetch(FetchDescriptor<PersonalSchemaV5.BatchUse>()).first { $0.rowID == badUse.rowID }?.grams == "damaged",
        "unrelated meal remains writable and retains damaged stock movement")
    badUse.grams = "-5"; try db.save()
    check(try !rePrepared.stockSnapshot().issues.isEmpty, "negative use never increases remaining stock")
    badUse.grams = "1"; badUse.portions = "damaged"; try db.save()
    check(try !rePrepared.stockSnapshot().issues.isEmpty, "unreadable portions never become zero")
    db.delete(badUse); try db.save()
    // Health arrival order survives a clock going backwards and process restart.
    let healthRoot = root.appendingPathComponent("health"), health = HealthArchive(root: healthRoot)
    func h(_ cursor: String, _ time: TimeInterval) -> HealthArchive.Batch {
        .init(type: "synthetic", receivedAt: Date(timeIntervalSince1970: time), anchor: Data(cursor.utf8), samples: Data(), added: 0, deletedIDs: [])
    }
    try await health.save(h("first", 200)); try await health.save(h("second", 100)); try await health.save(h("third", 100))
    check(try await HealthArchive(root: healthRoot).latest("synthetic")?.anchor == Data("third".utf8), "cursor follows successful atomic writes, not clocks or UUID sort")
    let gate = AuditAPIGate()
    let lateStore = DiaryStore(container: try DiaryStore.makeContainer(url: root.appendingPathComponent("late.store")), catalog: Catalog(url: nil))
    let late = MealSession(store: lateStore, diagnosticLog: MatchingLog(directory: root.appendingPathComponent("late-log")),
        api: MealAPI(transport: { _ in await gate.wait() }), keyProvider: { "synthetic-test-key" })
    await late.begin(day: today)
    let oldOwner = late.draft!.id
    late.draft?.transcript = "Первая синтетическая диктовка"; late.changed(); late.parse()
    while await gate.waiting < 1 { await Task.yield() }
    let cancelled = late.cancel()
    await late.begin(day: today.offset(-1))
    let newOwner = late.draft!.id
    late.draft?.transcript = "Вторая синтетическая диктовка"; late.changed(); late.parse()
    while await gate.waiting < 2 { await Task.yield() }
    try await gate.release("Старая еда|100")
    await cancelled?.value
    check(newOwner != oldOwner && late.draft?.id == newOwner && late.busy && late.draft?.rows.isEmpty == true,
        "late cancelled API response cannot clear a newer operation or replace another draft")
    try await gate.release("Новая еда|?")
    while late.busy { await Task.yield() }
    check(late.draft?.rows.first?.food == "Новая еда", "the current API operation completes normally")
    check(try await late.repository.drafts().values.first { $0.id == oldOwner }?.rows.isEmpty == true, "old input survives late response untouched")
    print("Audit regressions: V7→V8 disk migration, independent draft lifecycle, failure/retry, explicit plan, corrupt data, episodes, stock, Health order PASS")
}
