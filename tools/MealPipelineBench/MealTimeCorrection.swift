import Foundation
import SwiftData

/// Explicit maintenance request. Never runs without a caller-supplied exact UUID set.
@MainActor enum MealTimeCorrection {
    struct Request: Codable {
        var ids: [UUID]
        var day: String
        var meal: Meal
        var time: String
    }
    static func apply(_ request: Request, container: ModelContainer) throws {
        guard let date = ISO8601DateFormatter().date(from: request.time), Day(date).rawValue == request.day,
              date <= Date(), !request.ids.isEmpty, Set(request.ids).count == request.ids.count else { throw FoodError.invalidNumber }
        let db = ModelContext(container); db.autosaveEnabled = false
        let ids = request.ids
        let records = try db.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>(predicate: #Predicate { ids.contains($0.id) }))
        guard records.count == ids.count, records.allSatisfy({ $0.dayKey == request.day && $0.mealKey == request.meal.rawValue }) else {
            throw FoodError.database("Записи для исправления времени изменились.")
        }
        let rows = try records.map { try JSONDecoder().decode(MealRow.self, from: $0.data) }
        guard rows.allSatisfy({ $0.timing == nil || ($0.timing?.source == "user-estimated" && $0.timing?.consumedAt == date) }) else {
            throw FoodError.database("Время уже задано. Автоматическое исправление отменено.")
        }
        let episode = rows.compactMap { $0.timing?.episodeID }.first ?? UUID()
        do {
            for (record, original) in zip(records, rows) where original.timing == nil {
                var row = original
                var timing = MealTiming(mode: .earlier, selectedAt: date)
                timing.episodeID = episode; timing.startedAt = date; timing.consumedAt = date
                timing.updatedAt = Date(); timing.source = "user-estimated"
                row.timing = timing; record.data = try JSONEncoder().encode(row)
            }
            try db.save()
        } catch { db.rollback(); throw error }
    }
}
