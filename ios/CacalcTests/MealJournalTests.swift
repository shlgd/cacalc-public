import XCTest
import SwiftData
@testable import Cacalc

@MainActor final class MealJournalTests: XCTestCase {
    private func product(_ id: String = "synthetic", name: String = "Хлеб") -> Product {
        Product(id: id, name: name, brand: "Тест", basis: .g, calories: 210, protein: 5.8, fat: 0.5, carbs: 42, source: "synthetic-test")
    }
    private func store(url: URL? = nil) throws -> DiaryStore {
        DiaryStore(container: try DiaryStore.makeContainer(memory: url == nil, url: url), catalog: Catalog(url: nil))
    }
    func testPositionalOutputUsesDecimalAndKeepsMissingValues() throws {
        let value = try ExtractedMeal.decode(#"{"i":[["хлеб",1.42,"g"],["молоко",0.05,"l"],["огурец",200,null],["борщ",null,"portion"]]}"#)
        XCTAssertEqual(value.items[0].amount, Decimal(string: "1.42"))
        XCTAssertEqual(value.items[1].amount, Decimal(string: "0.05"))
        XCTAssertNil(value.items[2].unit); XCTAssertNil(value.items[3].amount)
        for invalid in [#"{"i":[["хлеб","1,5","g"]]}"#, #"{"i":[["хлеб",true,"g"]]}"#,
                        #"{"i":[["хлеб",0,"g"]]}"#, #"{"i":[["хлеб",-1,"g"]]}"#,
                        #"{"i":[["хлеб",2,"cup"]]}"#, #"{"i":[["хлеб",2]]}"#,
                        #"{"i":[["хлеб",2,"g",4]]}"#, #"{"i":[],"other":1}"#] {
            XCTAssertThrowsError(try ExtractedMeal.decode(invalid), invalid)
        }
        XCTAssertTrue(try ExtractedMeal.decode(#"{"i":[]}"#).items.isEmpty)
    }
    func testDismissedDraftRestoresWithoutRecordingThenCommitsOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("personal.store"), first = try store(url: url)
        let session = MealSession(store: first)
        await session.begin(day: first.today)
        let id = try XCTUnwrap(session.draft?.id)
        session.showing = false; await session.dismissed()
        let reopened = try store(url: url), restored = MealSession(store: reopened)
        await restored.load()
        XCTAssertEqual(restored.draft?.id, id)
        XCTAssertFalse(restored.canCommit)
        XCTAssertTrue(try reopened.page(for: first.today).items.isEmpty)
        await restored.begin(day: first.today.offset(1))
        XCTAssertEqual(restored.draft?.day, first.today)
        restored.addManual(name: "Еда в кафе")
        let rowID = try XCTUnwrap(restored.draft?.rows.first?.id)
        restored.updateRow(rowID) { $0.quantity = "125,5"; $0.unit = .g }
        restored.showing = false; await restored.dismissed()
        XCTAssertTrue(restored.canCommit)
        await restored.commit(); await restored.commit()
        let page = try reopened.page(for: first.today)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].row.amount, Decimal(string: "125.5"))
        XCTAssertNil(page.items[0].row.portion.calories)
        let persisted = try await restored.repository.loadDraft()
        XCTAssertNil(persisted)
        await restored.begin(day: first.today); await restored.discard()
        let discarded = try await restored.repository.loadDraft()
        XCTAssertNil(discarded)
        XCTAssertEqual(try reopened.page(for: first.today).items.count, 1)
    }
    func testUnprocessedDictationCannotBeDroppedByQuickSave() async throws {
        let s = try store(), session = MealSession(store: s)
        await session.begin(day: s.today)
        session.addManual(name: "Хлеб")
        session.draft?.transcript = "Ещё яблоко сто грамм"; session.changed()
        await session.close()
        XCTAssertFalse(session.canCommit)
        await session.commit()
        XCTAssertNotNil(session.error)
        XCTAssertEqual(session.draft?.transcript, "Ещё яблоко сто грамм")
        XCTAssertTrue(try s.page(for: s.today).items.isEmpty)
    }
    func testPartialNutritionAndUnitBoundaries() throws {
        var bread = product(); bread.calories = nil
        let row = MealRow(food: "хлеб", quantity: "12,5", unit: .g, product: bread)
        XCTAssertNil(row.portion.calories)
        XCTAssertEqual(row.portion.protein, Decimal(string: "0.725"))
        XCTAssertEqual(row.portion.fat, Decimal(string: "0.0625"))
        let unknown = MealRow(food: "Еда в ресторане")
        let summary = NutritionSummary([row.portion, unknown.portion])
        XCTAssertEqual(summary.missingCalories, 2); XCTAssertEqual(summary.missingProtein, 1)
        XCTAssertEqual(summary.known.protein, Decimal(string: "0.725"))
        XCTAssertNil(PortionSnapshot(product: bread, amount: 100, unit: .ml).protein)
        XCTAssertNil(PortionSnapshot(product: bread, amount: 2, unit: .pc).protein)
        XCTAssertEqual(PortionSnapshot(product: bread, amount: Decimal(string: "0.1"), unit: .kg).protein, 5.8)
        XCTAssertNoThrow(try unknown.validated())
        XCTAssertThrowsError(try MealRow(food: "хлеб", quantity: "много", unit: .g).validated())
    }
    func testPreviewReplacesEditedSnapshotAndKeepsExactFraction() {
        let day = Day(Date()), old = MealRow(food: "Хлеб", quantity: "40", unit: .g, product: product())
        let entry = DiaryItem(id: old.id, day: day, meal: .breakfast, row: old)
        var changed = old; changed.quantity = "12,5"
        let draft = MealDraft(day: day, meal: .breakfast, rows: [changed], editingEntryID: old.id)
        let preview = MealNutritionPreview(page: DiaryPageData(items: [entry], goals: nil), draft: draft)
        XCTAssertEqual(preview.before.count, 0)
        XCTAssertEqual(preview.after.known.calories, Decimal(string: "26.25"))
        XCTAssertEqual(preview.after.known.protein, Decimal(string: "0.725"))
        let calories = preview.nutrient(\.calories, missing: \.missingCalories)
        XCTAssertNil(calories.remaining); XCTAssertEqual(calories.progress, 0)
        XCTAssertEqual(calories.addedText, "+26")
    }
    func testPreviewUnknownCaloriesDoNotHideKnownMacrosOrInventRemainder() {
        var partial = product(); partial.calories = nil
        let draft = MealDraft(day: Day(Date()), meal: .lunch,
            rows: [MealRow(food: "Хлеб", quantity: "100", unit: .g, product: partial)])
        let preview = MealNutritionPreview(page: DiaryPageData(items: [], goals: Nutrition(calories: 100, protein: 5, fat: 70, carbs: 200)), draft: draft)
        let calories = preview.nutrient(\.calories, missing: \.missingCalories)
        XCTAssertEqual(calories.totalText, "—"); XCTAssertEqual(calories.addedText, "—")
        XCTAssertNil(calories.remaining)
        let protein = preview.nutrient(\.protein, missing: \.missingProtein)
        XCTAssertEqual(protein.total, Decimal(string: "5.8"))
        XCTAssertTrue(protein.exceeded); XCTAssertEqual(protein.progress, 1)
        XCTAssertEqual(protein.remaining, Decimal(string: "0.8"))
    }
    func testPreviewKeepsLowerBoundAndUsesSavedZero() {
        let day = Day(Date()), known = MealRow(food: "Хлеб", quantity: "100", unit: .g, product: product())
        let entry = DiaryItem(id: known.id, day: day, meal: .breakfast, row: known)
        let draft = MealDraft(day: day, meal: .lunch, rows: [MealRow(food: "Неизвестная еда")])
        let preview = MealNutritionPreview(page: DiaryPageData(items: [entry], goals: nil), draft: draft)
        let calories = preview.nutrient(\.calories, missing: \.missingCalories)
        XCTAssertEqual(calories.totalText, "≥ 210"); XCTAssertEqual(calories.addedText, "—")
        var zero = product(); zero.calories = 0; zero.protein = 0
        let zeroDraft = MealDraft(day: day, meal: .lunch, rows: [MealRow(food: "Ноль", quantity: "100", unit: .g, product: zero)])
        let zeroPreview = MealNutritionPreview(page: DiaryPageData(items: [], goals: nil), draft: zeroDraft)
        XCTAssertEqual(zeroPreview.nutrient(\.calories, missing: \.missingCalories).addedText, "+0")
    }
    func testPreviewReadsRealDatabaseAndCorrectDaysGoals() async throws {
        let s = try store(), repository = MealRepository(container: s.container)
        try s.setGoals(Nutrition(calories: 2000, protein: 150, fat: 70, carbs: 250))
        let row = MealRow(food: "Хлеб", quantity: "100", unit: .g, product: product())
        try await repository.commit(MealDraft(day: s.today, meal: .breakfast, rows: [row]))
        let loaded = try await repository.page(for: s.today)
        XCTAssertEqual(loaded.items.count, 1); XCTAssertEqual(loaded.total.calories, 210)
        let nextDay = try await repository.page(for: s.today.offset(1))
        XCTAssertEqual(nextDay.items.count, 0); XCTAssertEqual(nextDay.goals?.calories, 2000)
    }
    func testMigrationPreservesV2RecordsAndDrafts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("personal.store"), day = Day(rawValue: "2026-09-01"), id = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PersonalSchemaV2.self)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: config)
            let context = ModelContext(container)
            context.insert(PersonalSchema.Record(id: id, day: day, meal: .snack,
                productData: try JSONEncoder().encode(product()), amount: "12.5", unit: .g))
            context.insert(PersonalSchemaV2.ProductDraftRecord(try JSONEncoder().encode(ProductCreationDraft(product: product()))))
            try context.save()
        }
        let reopened = try store(url: url), page = try reopened.page(for: day)
        XCTAssertEqual(page.items.count, 1); XCTAssertEqual(page.items[0].id, id)
        XCTAssertEqual(page.items[0].meal, .snack); XCTAssertEqual(page.items[0].amount, Decimal(string: "12.5"))
        XCTAssertEqual(page.total.calories, Decimal(string: "26.25"))
        let productDraft = try await reopened.productRepository.loadDraft()
        XCTAssertEqual(productDraft?.name, "Хлеб")
        let repository = MealRepository(container: reopened.container)
        var updated = MealDraft(day: day, meal: .snack, rows: [page.items[0].row])
        updated.editingEntryID = id; updated.rows[0].quantity = "25"; updated.rows[0].snapshot = nil
        try await repository.commit(updated)
        XCTAssertEqual(try reopened.page(for: day).items.count, 1)
        XCTAssertEqual(try reopened.page(for: day).total.calories, Decimal(string: "52.5"))
    }
    func testUnknownFactSurvivesRestartThenLinksWithoutDuplicate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("personal.store"), s = try store(url: url)
        let repository = MealRepository(container: s.container), day = Day(Date())
        let row = MealRow(food: "хлеб", quantity: "40", unit: .g)
        var draft = MealDraft(day: day, meal: .breakfast, rows: [row], transcript: "хлеб сорок грамм")
        try await repository.persist(draft)
        let restoredDraft = try await MealRepository(container: try store(url: url).container).loadDraft()
        XCTAssertEqual(restoredDraft, draft)
        try await repository.commit(draft); try await repository.commit(draft)
        let reopened = try store(url: url)
        XCTAssertEqual(reopened.items.count, 1); XCTAssertEqual(reopened.streak, 1)
        XCTAssertNil(reopened.items[0].row.portion.calories)
        draft.rows[0].product = product(); draft.editingEntryID = row.id
        try await repository.commit(draft)
        let page = try reopened.page(for: day)
        XCTAssertEqual(page.items.count, 1); XCTAssertEqual(page.items[0].id, row.id)
        XCTAssertEqual(page.total.calories, 84)
        let history = try await repository.history(); XCTAssertEqual(history.first?.count, 1)
        var changed = ProductCreationDraft(product: product()); changed.calories = "300"
        _ = try await s.productRepository.commit(changed)
        XCTAssertEqual(try reopened.page(for: day).total.calories, 84, "Исторический снимок не меняется")
    }
    func testFailedTransactionKeepsDraftAndNoPartialMeal() async throws {
        let s = try store(), repository = MealRepository(container: s.container)
        let draft = MealDraft(day: Day(Date()), meal: .lunch, rows: [MealRow(food: "Первое"), MealRow(food: "Второе")])
        try await repository.persist(draft)
        await repository.injectSaveFailure()
        do { try await repository.commit(draft); XCTFail("Save must fail") } catch {}
        XCTAssertTrue(try s.page(for: draft.day).items.isEmpty)
        let restored = try await repository.loadDraft(); XCTAssertEqual(restored, draft)
        try await repository.commit(draft)
        XCTAssertEqual(try s.page(for: draft.day).items.count, 2)
    }
    func testRankingDoesNotGuessWeakSingleOrTiedCandidates() {
        let a = product("a", name: "Хлеб ржаной"), b = product("b", name: "Хлеб пшеничный")
        XCTAssertNil(MealMatcher.suggestion(MealMatcher.rank("хлеб", products: [a], history: [])))
        let now = Date(), history = [a, b].map { MatchHistory(phrase: "хлеб", product: $0, count: 3, lastUsed: now) }
        XCTAssertNil(MealMatcher.suggestion(MealMatcher.rank("хлеб", products: [a, b], history: history, now: now)))
        let only = MealMatcher.rank("хлеб", products: [a, b], history: [history[0]], now: now)
        XCTAssertEqual(MealMatcher.suggestion(only)?.id, "a")
        XCTAssertTrue(MealMatcher.rank("хлеб пшеничный", products: [a], history: history, now: now).isEmpty)
    }
    func testLegacyDraftCannotDuplicateAlreadyMigratedEntry() async throws {
        let s = try store(), repository = MealRepository(container: s.container)
        let row = MealRow(food: "Хлеб", quantity: "40", unit: .g, product: product())
        try await repository.commit(MealDraft(day: s.today, meal: .breakfast, rows: [row]))
        try s.persistDraft(FoodDraft(day: s.today, meal: .breakfast, product: product(), quantity: "50", basis: .g, editingID: row.id))
        try s.commitDraft()
        XCTAssertEqual(s.items.count, 1); XCTAssertEqual(s.items[0].id, row.id)
        XCTAssertEqual(s.total.calories, 105)
        try s.remove(row.id)
        XCTAssertTrue(s.items.isEmpty)
    }
    func testAPIRequestIsBoundedAndContainsOnlyCurrentText() throws {
        let request = try MealAPI.request(text: "хлеб 40 грамм", key: "synthetic-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(request.url?.absoluteString, "https://polza.ai/api/v1/chat/completions")
        XCTAssertEqual(body["model"] as? String, MealAPI.model)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.count, 2)
        XCTAssertFalse(String(data: request.httpBody!, encoding: .utf8)!.contains("synthetic-key"))
    }
    func testStaleAPIResponseCannotReplaceEditedDraft() async throws {
        let s = try store()
        let api = MealAPI(transport: { request in
            try await Task.sleep(for: .milliseconds(160))
            let data = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"i\":[[\"хлеб\",40,\"g\"]]}"}}]}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let meal = MealSession(store: s, api: api, keyProvider: { "synthetic-key" })
        await meal.begin(day: Day(Date()))
        meal.draft?.transcript = "хлеб сорок грамм"; meal.changed(); meal.parse()
        try await Task.sleep(for: .milliseconds(60))
        meal.addManual(name: "Ручная строка")
        while meal.busy { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(meal.draft?.rows.map(\.food), ["Ручная строка"])
        XCTAssertEqual(meal.draft?.transcript, "хлеб сорок грамм")
    }
}
