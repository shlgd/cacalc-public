import XCTest
import SwiftData
@testable import Cacalc

@MainActor final class CacalcTests: XCTestCase {
    func product() -> Product {
        Product(id: "test", name: "Тестовый продукт", brand: "Synthetic", basis: .g,
                calories: 45, protein: Decimal(string: "2.9"), fat: Decimal(string: "1.5"), carbs: Decimal(string: "4.9"), source: "synthetic-test")
    }
    func store() throws -> DiaryStore {
        DiaryStore(container: try DiaryStore.makeContainer(memory: true), catalog: Catalog(url: nil))
    }
    func add(_ s: DiaryStore, day: Day, amount: String = "100") throws {
        try s.persistDraft(FoodDraft(day: day, meal: .breakfast, product: product(), quantity: amount, basis: .g))
        try s.commitDraft()
    }
    func testDecimalPortionsAndInvalidInput() throws {
        XCTAssertEqual(try Numbers.parse("150,5"), Decimal(string: "150.5"))
        XCTAssertEqual(Numbers.source("0.000123456789"), Decimal(string: "0.000123456789"))
        let value = try product().portion(Decimal(string: "150.5")!, unit: .g)
        XCTAssertEqual(value.calories, Decimal(string: "67.725"))
        XCTAssertEqual(value.protein, Decimal(string: "4.3645"))
        for invalid in ["", "-2", "NaN", "Infinity", "1e6", "2.1.1", "1000001"] {
            XCTAssertThrowsError(try Numbers.parse(invalid))
        }
        XCTAssertThrowsError(try Numbers.parse("0", positive: true))
        XCTAssertThrowsError(try product().portion(100, unit: .ml))
        var p = product(); p.basis = .unknown
        XCTAssertThrowsError(try p.portion(100, unit: .g))
        p.basis = .g; p.protein = nil
        XCTAssertNil(p.nutrition)
        XCTAssertThrowsError(try p.portion(100, unit: .g))
    }
    func testBudgetDoesNotDivideByZeroOrWrapRing() {
        XCTAssertEqual(Budget(eaten: 2200, target: 2000).progress, 1)
        XCTAssertEqual(Budget(eaten: 2200, target: 2000).remainder, 200)
        XCTAssertTrue(Budget(eaten: 2200, target: 2000).exceeded)
        XCTAssertNil(Budget(eaten: 50, target: nil).remainder)
        XCTAssertEqual(Budget(eaten: 50, target: 0).progress, 0)
    }
    func testDaysSwipesAndTimeZones() {
        XCTAssertEqual(Day.swipe(-100, vertical: 2), 1)
        XCTAssertEqual(Day.swipe(100, vertical: 2), -1)
        XCTAssertEqual(Day.swipe(-90, vertical: 160), 0)
        XCTAssertEqual(Day(rawValue: "2026-12-31").offset(1).rawValue, "2027-01-01")
        let instant = ISO8601DateFormatter().date(from: "2026-09-06T22:30:00Z")!
        let moscow = Day(instant, zone: TimeZone(identifier: "Europe/Moscow")!)
        let la = Day(instant, zone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(moscow.rawValue, "2026-09-07")
        XCTAssertEqual(la.rawValue, "2026-09-06")
        XCTAssertEqual(Day(rawValue: moscow.rawValue).rawValue, "2026-09-07")
    }
    func testDayTitles() {
        let today = Day(rawValue: "2026-09-06")
        XCTAssertEqual(today.title(relativeTo: today), "Сегодня")
        XCTAssertEqual(today.offset(-1).title(relativeTo: today), "Вчера")
        XCTAssertEqual(today.offset(1).title(relativeTo: today), "Завтра")
        XCTAssertEqual(Day(rawValue: "2026-09-09").title(relativeTo: today), "Среда 09.09")
        XCTAssertEqual(Day(rawValue: "2026-02-03").title(relativeTo: today), "Вторник 03.02")
    }
    func testSeriesDoesNotTreatFuturePlanAsFact() async throws {
        let s = try store(); let today = s.today
        try add(s, day: today.offset(-2)); try add(s, day: today.offset(-1))
        XCTAssertEqual(s.streak, 2)
        try add(s, day: today.offset(1))
        XCTAssertTrue(s.future); XCTAssertEqual(s.streak, 2)
        try add(s, day: today)
        XCTAssertEqual(s.streak, 3)
        s.refreshClock(today.offset(1).date)
        await s.reloadAsync()
        XCTAssertFalse(s.future); XCTAssertEqual(s.streak, 3)
        XCTAssertEqual(s.total.calories, 0)
        let plan = try XCTUnwrap(s.items.first?.row.timing?.episodeID)
        try await MealRepository(container: s.container).consumeEpisode(plan, now: today.offset(1).date)
        await s.reloadAsync()
        XCTAssertEqual(s.streak, 4)
        try s.remove(s.items[0].id)
        XCTAssertEqual(s.streak, 3)
        s.select(today.offset(-1)); try s.remove(s.items[0].id)
        XCTAssertEqual(s.streak, 1)
    }
    func testNeighborPageDoesNotChangeSelectionOrMixDays() throws {
        let s = try store(); let today = s.today
        try add(s, day: today.offset(-1), amount: "200")
        try add(s, day: today, amount: "100")
        let previous = try s.page(for: today.offset(-1))
        let next = try s.page(for: today.offset(1))
        XCTAssertEqual(previous.total.calories, 90)
        XCTAssertEqual(next.total.calories, 0)
        XCTAssertEqual(s.selectedDay, today)
        XCTAssertEqual(s.total.calories, 45)
    }
    func testGoalHistory() throws {
        let s = try store(); let initial = Nutrition(calories: 2000, protein: 100, fat: 70, carbs: 250)
        try s.setGoals(initial)
        s.select(s.today.offset(-10)); XCTAssertEqual(s.goals, initial)
        let next = Nutrition(calories: 2100, protein: 110, fat: 75, carbs: 260)
        try s.setGoals(next)
        XCTAssertEqual(s.goals, initial)
        s.select(s.today); XCTAssertEqual(s.goals, next)
        s.select(s.today.offset(3)); XCTAssertEqual(s.goals, next)
    }
    func testDraftAndDiarySurviveContainerReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("personal.store")
        let s = DiaryStore(container: try DiaryStore.makeContainer(url: url), catalog: Catalog(url: nil))
        try s.persistDraft(FoodDraft(day: s.today, meal: .lunch, product: product(), quantity: "125,5", basis: .g))
        let reopened = DiaryStore(container: try DiaryStore.makeContainer(url: url), catalog: Catalog(url: nil))
        XCTAssertEqual(reopened.draft?.quantity, "125,5")
        XCTAssertEqual(reopened.total, .zero)
        try reopened.commitDraft()
        let after = DiaryStore(container: try DiaryStore.makeContainer(url: url), catalog: Catalog(url: nil))
        XCTAssertNil(after.draft)
        XCTAssertEqual(after.total.calories, Decimal(string: "56.475"))
    }
    func testSaveFailurePreservesDraftAndDoesNotCreateEntry() throws {
        let s = try store()
        try s.persistDraft(FoodDraft(day: s.today, meal: .dinner, product: product(), quantity: "100", basis: .g))
        s.beforeSave = { throw FoodError.database("Simulated disk failure") }
        XCTAssertThrowsError(try s.commitDraft())
        XCTAssertNotNil(s.draft)
        s.beforeSave = nil
        try s.reload(); XCTAssertTrue(s.items.isEmpty)
        let reopened = DiaryStore(container: s.container, catalog: Catalog(url: nil))
        XCTAssertNotNil(reopened.draft)
        try reopened.commitDraft(); XCTAssertEqual(reopened.total.calories, 45)
    }
    func testCustomCardAndBasisAreRememberedWithoutChangingHistory() async throws {
        let s = try store(); var p = product(); p.basis = .unknown
        try s.persistDraft(FoodDraft(day: s.today, meal: .breakfast, product: p, quantity: "100", basis: .g))
        try s.commitDraft()
        XCTAssertEqual(try s.personalProducts().first?.basis, .g)
        var changed = product(); changed.source = "user-label"; changed.calories = 90
        try s.persistDraft(FoodDraft(day: s.today, meal: .lunch, product: changed, quantity: "100", basis: .g, savesPersonalProduct: true))
        try s.commitDraft()
        XCTAssertEqual(s.total.calories, 135)
        XCTAssertEqual(s.items.first(where: { $0.meal == .breakfast })?.product?.calories, 45)
        XCTAssertEqual(try s.personalProducts().first?.calories, 90)
    }
    func testScannerGateAndChecksums() {
        let gate = ScanGate()
        XCTAssertFalse(gate.accept("4600605026534"))
        XCTAssertTrue(gate.accept("4600605026533"))
        XCTAssertFalse(gate.accept("4600605026533"))
        XCTAssertFalse(gate.accept("4600605033951"))
        XCTAssertTrue(Barcode.valid("4600605033951"))
        XCTAssertTrue(Barcode.valid("036000291452"))
    }
    func testRealCatalogOfflineAndLatency() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "catalog", withExtension: "sqlite"))
        let catalog = Catalog(url: url)
        let milks = try await catalog.search("молоко")
        let milk = try XCTUnwrap(milks.first { $0.id == "basic:no:01.229" })
        XCTAssertEqual(milk.name, "Молоко 1%")
        XCTAssertEqual(milk.calories, 41)
        XCTAssertEqual(milk.protein, Decimal(string: "3.5"))
        XCTAssertNil(milk.barcode)
        let apples = try await catalog.search("яблоко")
        let apple = try XCTUnwrap(apples.first { $0.id == "basic:no:06.758" })
        XCTAssertEqual(apple.calories, 46)
        XCTAssertEqual(apple.basis, .g)
        let start = ContinuousClock.now
        for _ in 0..<20 { _ = try await catalog.search("молоко") }
        print("CACALC_SEARCH_20_QUERIES: \(start.duration(to: .now))")
        let none = try await catalog.search("%__нет такого продукта")
        XCTAssertTrue(none.isEmpty)
    }
    func testDaySwitchPerformance() throws {
        let s = try store()
        try add(s, day: s.today)
        measure {
            for i in -15..<15 { s.select(s.today.offset(i)) }
        }
    }
}
