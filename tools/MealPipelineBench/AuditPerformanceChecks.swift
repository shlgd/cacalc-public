import Foundation
import SwiftData

private final class AuditEncoderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    func encode(_ text: String) -> [Float] { lock.withLock { texts.append(text) }; return [1, 0] }
    var count: Int { lock.withLock { texts.count } }
}
private actor AuditBoot {
    var calls = 0
    func prepare() throws { calls += 1; if calls == 1 { throw FoodError.database("synthetic transient load failure") } }
}
@MainActor func checkAuditCachesAndWriter() async throws {
    func check(_ value: Bool, _ message: String = "") { precondition(value, message) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cacalc-cache-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = AuditEncoderCounter()
    let semantic = SemanticProductSearch(cacheURL: root.appendingPathComponent("cache.json"), encoder: { probe.encode($0) })
    let cards = ["Яблоко", "Банан", "Молоко"].enumerated().map { Product(id: "synthetic:\($0.offset)", name: $0.element, brand: "", basis: .g, source: "synthetic-test") }
    check(await semantic.scores("query", products: cards).scores.count == 3)
    let firstCount = probe.count
    _ = await semantic.scores("subset", products: [cards[0]])
    _ = await semantic.scores("query", products: cards)
    check(probe.count == firstCount + 1, "subset scoring must not delete other product vectors")
    var edited = cards; edited[1].name = "Банан новый"
    _ = await semantic.scores("query", products: edited)
    check(probe.count == firstCount + 2, "one changed identity encodes one vector")
    await semantic.reconcileCatalog([edited[0]])
    _ = await semantic.scores("query", products: edited)
    check(probe.count == firstCount + 4, "only explicit full-catalog reconciliation prunes missing IDs")
    let blocked = root.appendingPathComponent("file-parent")
    try Data("synthetic obstacle".utf8).write(to: blocked)
    let unwritable = SemanticProductSearch(cacheURL: blocked.appendingPathComponent("cache.json"), encoder: { probe.encode($0) })
    check(await unwritable.scores("first", products: cards).scores.count == 3, "optional disk cache failure retains computed scores")
    check(await unwritable.scores("second", products: cards).scores.count == 3, "cache failure doesn't disable subsequent searches")
    let boot = AuditBoot()
    let retry = SemanticProductSearch(cacheURL: root.appendingPathComponent("retry.json"), encoder: { probe.encode($0) }, prepare: { try await boot.prepare() }, retryDelay: 0)
    check(await retry.scores("retry", products: cards).status.hasPrefix("error:"))
    check(await retry.scores("retry", products: cards).scores.count == 3, "failed preparation task is released and retried")
    let container = try DiaryStore.makeContainer(url: root.appendingPathComponent("writer.store"))
    let repository = MealRepository(container: container)
    var failures = 0
    let writer = DraftWriter<MealDraft>(write: { value in
        try await Task.sleep(for: .milliseconds(10))
        try await repository.persist(value)
    }, failed: { _ in failures += 1 })
    var draft = MealDraft(day: Day(Date()), meal: .breakfast)
    let started = Date()
    for i in 0..<1000 {
        draft.transcript = "synthetic \(i)"; draft.revision = UUID()
        draft.auditPending = (draft.auditPending ?? []) + [.init(name: "synthetic", fields: ["eventID": UUID().uuidString, "index": String(i)])]
        writer.submit(draft, id: draft.id)
    }
    try await writer.flush()
    let coalescedWrites = writer.writes, coalescedSeconds = Date().timeIntervalSince(started)
    check(writer.writes <= 2 && writer.peakPending == 1, "1000 snapshots coalesce into bounded writes")
    check(try await repository.loadDraft() == draft, "flush persists the latest fields and every outbox event")
    await repository.injectSaveFailure(); draft.transcript = "last snapshot"; writer.submit(draft, id: draft.id)
    try await writer.flush()
    let retried = try await repository.loadDraft()
    check(failures == 1 && retried == draft, "transient write failure shows an error and flush retries latest")
    let finalDraft = draft
    var beforeClose = draft; beforeClose.transcript = "intermediate before close"
    writer.submit(beforeClose, id: draft.id)
    let lastEdit = Task { @MainActor in
        try await Task.sleep(for: .milliseconds(2)); writer.submit(finalDraft, id: finalDraft.id)
    }
    try await writer.flush(); try await lastEdit.value
    check(try await repository.loadDraft() == finalDraft, "close barrier includes edits submitted during I/O")
    print("Audit cache/writer PASS: subset vectors, edit/prune, cache failure, preparation retry; 1000 changes → \(coalescedWrites) initial writes, peakPending=\(writer.peakPending), \(coalescedSeconds) s; outbox=1000")
}

@MainActor func checkAuditInvalidation() async throws {
    func check(_ value: Bool, _ message: String) { precondition(value, message) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cacalc-invalidation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let container = try DiaryStore.makeContainer(url: root.appendingPathComponent("synthetic.store"))
    let catalog = Catalog(url: URL(fileURLWithPath: "ios/Resources/catalog.sqlite"))
    let products = ProductRepository(container: container), meals = MealRepository(container: container), prepared = PreparedRepository(container: container)
    let initial = try await products.searchIndex(catalog)
    var card = ProductCreationDraft(); card.name = "Синтетическая карточка"; card.calories = "100"; card.protein = "1"; card.fat = "2"; card.carbs = "3"
    let product = try await products.commit(card)
    check(try await products.searchIndex(catalog).products.contains { $0.id == product.id }, "fresh product invalidates index")
    var edit = ProductCreationDraft(product: product); edit.name = "Синтетическая правка"
    let edited = try await products.commit(edit)
    check(try await products.searchIndex(catalog).products.first { $0.id == product.id }?.name == edited.name, "edited identity invalidates index")
    try await products.remove(edited)
    check(try await products.searchIndex(catalog).products.count == initial.products.count, "hidden personal product leaves cached catalog")
    let recipe = RecipeTemplate(name: "Синтетическая партия", ingredients: [RecipeIngredient(product: product, actual: "100")])
    try prepared.create(CookingState(recipe: recipe, yieldText: "200", portionText: "2"))
    let batch = try prepared.stocks().first!
    let before = try await products.searchIndex(catalog).products.first { $0.preparedBatchID == batch.id }!
    try prepared.adjust(batch.id, grams: 150, portions: 2)
    let after = try await products.searchIndex(catalog).products.first { $0.preparedBatchID == batch.id }!
    check(before.preparedNote != after.preparedNote, "adjusted stock invalidates cached candidate detail")
    let day = Day(Date()), row = MealRow(food: product.name, quantity: "50", unit: .g, product: batch.product, batchPortions: 1)
    let consumed = MealDraft(day: day, meal: .breakfast, rows: [row])
    _ = try await meals.usage(); try await meals.commit(consumed)
    check(try await meals.usage().contains { $0.product.id == batch.product.id && $0.count == 1 }, "commit invalidates consumption snapshot")
    check(try prepared.stocks().first!.grams == 100, "real diary commit reaches stock consumer")
    var amended = consumed; amended.id = UUID(); amended.editingEntryID = row.id; amended.rows[0].quantity = "25"
    try await meals.commit(amended)
    check(try await meals.usage().first?.count == 1, "edit invalidates usage without counting another consumption")
    check(try prepared.stocks().first!.grams == 125, "edited food reconciles stock")
    try await meals.remove(row.id)
    check(try await meals.usage().isEmpty && prepared.stocks().first!.grams == 150, "delete invalidates usage and returns stock")
    try prepared.close(batch.batch)
    check(try await products.searchIndex(catalog).products.allSatisfy { $0.preparedBatchID != batch.id }, "closed batch leaves cached search")
    print("Audit invalidation PASS: new/edit/hidden product, adjusted/closed batch, diary commit/edit/delete and consumption cache")
}

@MainActor func checkAuditPerformance() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cacalc-performance-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func milliseconds(_ started: Date) -> Double { Date().timeIntervalSince(started) * 1000 }
    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    var report: [String: Double] = [:]
    for count in [500, 5000] {
        let container = try DiaryStore.makeContainer(url: root.appendingPathComponent("\(count).store"))
        let db = ModelContext(container); db.autosaveEnabled = false
        let today = Day(Date())
        for i in 0..<count {
            let product = Product(id: "synthetic:\(i % 20)", name: "Синтетический продукт", brand: "", basis: .g,
                calories: 100, protein: 10, fat: 3, carbs: 8, source: "synthetic-audit")
            let row = try MealRow(food: "Синтетический продукт", quantity: "100", unit: .g, product: product).validated()
            db.insert(PersonalSchemaV3.JournalRecord(id: row.id, day: today, meal: .lunch, data: try JSONEncoder().encode(row)))
            try StorageRevision.index(id: row.id, day: today.rawValue, row: row, db: db)
        }
        try StorageRevision.touch("journal", db: db); try db.save()
        let meals = MealRepository(container: container)
        var start = Date(); _ = try await meals.usage(); report["usage_\(count)_cold_ms"] = milliseconds(start)
        var values: [Double] = []
        _ = try await meals.usage()
        for _ in 0..<20 {
            start = Date(); let usage = try await meals.usage(); values.append(milliseconds(start))
            precondition(usage.reduce(0) { $0 + $1.count } == count)
        }
        report["usage_\(count)_cached_median_ms"] = median(values)
        print("PERFORMANCE usage_\(count)_20products_repetitions_ms=\(values)")
        // Same historical fixture as the first audit: no current/recent entries,
        // 300 old days, incomplete food snapshots. Measure the real UI boundary.
        let history = try DiaryStore.makeContainer(url: root.appendingPathComponent("history-\(count).store"))
        let historyDB = ModelContext(history); historyDB.autosaveEnabled = false
        for i in 0..<count {
            var row = MealRow(food: "Синтетическая историческая еда")
            row.timing = MealTiming(mode: .earlier, startedAt: today.offset(-60).date, selectedAt: today.offset(-60).date, consumedAt: today.offset(-60).date)
            let day = today.offset(-60 - i % 300)
            historyDB.insert(PersonalSchemaV3.JournalRecord(id: row.id, day: day, meal: .lunch, data: try JSONEncoder().encode(row)))
            try StorageRevision.index(id: row.id, day: day.rawValue, row: row, db: historyDB)
        }
        try StorageRevision.touch("journal", db: historyDB); try historyDB.save()
        let diary = DiaryStore(container: history, catalog: Catalog(url: nil))
        start = Date(); await diary.reloadAsync(); report["diary_\(count)_cold_ms"] = milliseconds(start)
        values = []
        for _ in 0..<20 { start = Date(); await diary.reloadAsync(); values.append(milliseconds(start)) }
        report["diary_\(count)_cached_median_ms"] = median(values)
        print("PERFORMANCE diary_\(count)_old300days_repetitions_ms=\(values)")
    }
    let container = try DiaryStore.makeContainer(url: root.appendingPathComponent("catalog.store"))
    let products = ProductRepository(container: container), catalog = Catalog(url: URL(fileURLWithPath: "ios/Resources/catalog.sqlite"))
    _ = try await products.searchIndex(catalog)
    _ = try await products.searchIndex(catalog)
    var values: [Double] = []
    for _ in 0..<20 { let start = Date(); _ = try await products.searchIndex(catalog); values.append(milliseconds(start)) }
    report["index_474_cached_median_ms"] = median(values)
    let diary = DiaryStore(container: container, catalog: catalog)
    _ = try await diary.rankedSearch("молоко"); _ = try await diary.rankedSearch("молоко")
    values = []
    for _ in 0..<20 { let start = Date(); _ = try await diary.rankedSearch("молоко"); values.append(milliseconds(start)) }
    report["ranked_search_one_call_median_ms"] = median(values)
    let data = try JSONEncoder().encode(report)
    if let output = ProcessInfo.processInfo.environment["CACALC_PERFORMANCE_OUTPUT"] { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
    print("AUDIT_PERFORMANCE_SWIFT_O_MAC: " + String(decoding: data, as: UTF8.self))
    print("AUDIT_PERFORMANCE_MEMORY: \(ProcessMemory.fields())")
}
