import Foundation
import SwiftData

@MainActor func checkVariantSelection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DiaryStore(container: try DiaryStore.makeContainer(url: directory.appendingPathComponent("test.store")), catalog: Catalog(url: URL(fileURLWithPath: "ios/Resources/catalog.sqlite")))
    let repo = PreparedRepository(container: store.container)
    let ingredient = Product(id: "synthetic-lentil", name: "Чечевица", brand: "", basis: .g, calories: 300, protein: 20, fat: 2, carbs: 50, source: "synthetic")
    try repo.create(CookingState(recipe: RecipeTemplate(name: "Пюре из чечевицы", ingredients: [RecipeIngredient(product: ingredient, planned: "250", actual: "250")]), yieldText: "840", portionText: "4"))
    let batch = try repo.stocks()[0].batch
    // Replay recorded semantic evidence, not a fresh model inference.
    let session = MealSession(store: store, diagnosticLog: MatchingLog(directory: directory.appendingPathComponent("logs")), semanticScorer: { _, products in
        .init(scores: Dictionary(uniqueKeysWithValues: products.map { ($0.id, 0.9125565802174549) }), status: "synthetic-replay")
    })
    await session.begin(day: store.today)
    let owner = session.draft!.id
    session.draft?.audioFile = "synthetic.wav"; session.draft?.dictationID = UUID()
    _ = try await session.acceptLivePhrase("одна порция чечевичного пюре", through: 48000, owner: owner, file: "synthetic.wav", boundary: true)
    await session.waitForLiveMatching()
    precondition(session.draft!.rows.count == 1)
    let row = session.draft!.rows[0]
    precondition(row.product?.preparedBatchID == batch.id && row.amount == 210 && row.matchAttention == nil && row.suggested, "variant selects batch without warning")
    session.updateRow(row.id) { $0.quantity = "220" }
    _ = try await session.acceptLivePhrase("одна порция чечевичного пюре", through: 48000, owner: owner, file: "synthetic.wav", boundary: true)
    await session.waitForLiveMatching()
    precondition(session.draft!.rows.count == 1 && session.draft!.rows[0].id == row.id && session.draft!.rows[0].amount == 220)
    let stock = try repo.stocks()[0]
    precondition(stock.grams == 840, "draft never consumes stock")
    print("Supported variant session replay passed")
}
