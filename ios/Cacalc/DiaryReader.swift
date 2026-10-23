import Foundation
import SwiftData

struct DiaryReloadSnapshot: Sendable {
    var pages: [Day: DiaryPageData]
    var history: [DiaryItem]
    var streak: Int
    var issues: [StoredDataIssue]
}

/// Contexts are created on this executor. UI only applies immutable value snapshots.
actor DiaryReader {
    private let container: ModelContainer
    private var cached: (key: String, selected: Day, today: Day, value: DiaryReloadSnapshot)?
    init(container: ModelContainer) { self.container = container }
    func load(selected: Day, today: Day) throws -> DiaryReloadSnapshot {
        let db = ModelContext(container); db.autosaveEnabled = false
        let key = try StorageRevision.token("journal", db: db) + StorageRevision.token("goals", db: db)
        if let cached, cached.key == key, cached.selected == selected, cached.today == today { return cached.value }
        let value = try Self.snapshot(container: container, selected: selected, today: today)
        cached = (key, selected, today, value)
        return value
    }
    /// Also available to synchronous offline/legacy callers, using exactly the same reader.
    static func snapshot(container: ModelContainer, selected: Day, today: Day) throws -> DiaryReloadSnapshot {
        let db = ModelContext(container); db.autosaveEnabled = false
        // Repair missing metadata from pre-V8/raw import writers once. No payload pass on a hit.
        if try db.fetchCount(FetchDescriptor<PersonalSchemaV3.JournalRecord>()) !=
            db.fetchCount(FetchDescriptor<PersonalSchemaV8.JournalIndex>()) {
            let indexed = Set(try db.fetch(FetchDescriptor<PersonalSchemaV8.JournalIndex>()).map(\.id))
            for record in try db.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>()) where !indexed.contains(record.id) {
                try StorageRevision.index(id: record.id, day: record.dayKey,
                    row: try? JSONDecoder().decode(MealRow.self, from: record.data), db: db)
            }
            try db.save()
        }
        var pages: [Day: DiaryPageData] = [:], history: [DiaryItem] = [], issues: [StoredDataIssue] = []
        var requested: Set<Day> = [selected, today]
        #if os(iOS)
        requested.formUnion((0..<8).map { today.offset($0) })
        #endif
        for day in requested {
            let value = try DiaryStore.loadPage(for: day, context: db)
            pages[day] = value; issues += value.issues
        }
        let from = today.offset(-28).rawValue, to = today.rawValue
        let recent = try db.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>(
            predicate: #Predicate { $0.dayKey >= from && $0.dayKey < to }))
        for record in recent {
            do {
                let row = try JSONDecoder().decode(MealRow.self, from: record.data)
                guard let meal = Meal(rawValue: record.mealKey), row.id == record.id else { throw FoodError.invalidNumber }
                if row.timing?.isPlanned != true { history.append(DiaryItem(id: row.id, day: Day(rawValue: record.dayKey), meal: meal, row: row)) }
            } catch { issues.append(.init(id: record.id.uuidString, message: "История неполна: запись \(record.id) не прочитана. Данные сохранены.")) }
        }
        let legacy = try db.fetch(FetchDescriptor<PersonalSchema.Record>(
            predicate: #Predicate { $0.dayKey >= from && $0.dayKey < to }))
        let journalIDs = Set(recent.map(\.id))
        for record in legacy where !journalIDs.contains(record.id) {
            do {
                let product = try JSONDecoder().decode(Product.self, from: record.productData)
                guard let meal = Meal(rawValue: record.mealKey), let unit = Basis(rawValue: record.unit) else { throw FoodError.unknownBasis }
                history.append(DiaryItem(id: record.id, day: Day(rawValue: record.dayKey), meal: meal,
                    product: product, amount: try Numbers.parse(record.amount, positive: true), unit: unit))
            } catch { issues.append(.init(id: record.id.uuidString, message: "История неполна: старая запись \(record.id) не прочитана. Данные сохранены.")) }
        }
        let consumed = try db.fetch(FetchDescriptor<PersonalSchemaV8.ConsumedDay>())
        var days = Set(consumed.filter { $0.count > 0 }.map { Day(rawValue: $0.dayKey) })
        for day in consumed where day.unreadable > 0 {
            issues.append(.init(id: "day:" + day.dayKey, message: "История за \(day.dayKey) неполна. Повреждённые записи сохранены; серия может быть неполной."))
        }
        var legacyDays = FetchDescriptor<PersonalSchema.Record>()
        legacyDays.propertiesToFetch = [\.dayKey]
        days.formUnion(try db.fetch(legacyDays).map { Day(rawValue: $0.dayKey) })
        var seen = Set<String>()
        return DiaryReloadSnapshot(pages: pages, history: history, streak: Day.streak(days, today: today),
            issues: issues.filter { seen.insert($0.id).inserted })
    }
}
