import Foundation
import SwiftData

/// Identical synthetic fixture for the archived V7 tree and the current tree.
/// Each runs in its own fresh process; no UI, models, personal store or network.
@main struct MemoryProbe {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CACALC_MEMORY_PROBE_ROOT"]!)
        let container = try DiaryStore.makeContainer(url: root.appendingPathComponent("synthetic.store"))
        let db = ModelContext(container); db.autosaveEnabled = false
        let day = Day(Date())
        for i in 0..<5000 {
            let product = Product(id: "synthetic:\(i % 20)", name: "Синтетический продукт", brand: "", basis: .g,
                calories: 100, protein: 10, fat: 3, carbs: 8, source: "synthetic-audit")
            let row = try MealRow(food: "Синтетический продукт", quantity: "100", unit: .g, product: product).validated()
            db.insert(PersonalSchemaV3.JournalRecord(id: row.id, day: day, meal: .lunch, data: try JSONEncoder().encode(row)))
        }
        try db.save()
        let repository = MealRepository(container: container)
        var output: [String: Any] = ["scope": "Mac Swift -O, fresh process, 5000 rows/20 products, whole-process memory",
                                    "seeded": ProbeMemory.fields()]
        let cold = Date(); _ = try await repository.usage(); output["cold_ms"] = Date().timeIntervalSince(cold) * 1000
        output["afterFirstRead"] = ProbeMemory.fields()
        var times: [Double] = []
        for _ in 0..<20 {
            let started = Date(), values = try await repository.usage()
            precondition(values.reduce(0) { $0 + $1.count } == 5000)
            times.append(Date().timeIntervalSince(started) * 1000)
        }
        output["repetitions_ms"] = times; output["median_ms"] = times.sorted()[10]
        output["afterRepeatedReads"] = ProbeMemory.fields()
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CACALC_MEMORY_PROBE_OUTPUT"]!), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
}
