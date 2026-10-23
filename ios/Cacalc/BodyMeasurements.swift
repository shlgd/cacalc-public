import Foundation
import SwiftData

enum MeasurementKind: String, Codable, CaseIterable, Identifiable {
    case weight, waist
    var id: String { rawValue }
    var title: String { self == .weight ? "Вес" : "Талия" }
    var unit: String { self == .weight ? "кг" : "см" }
}
struct BodyMeasurement: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: MeasurementKind
    var value: Decimal
    var measuredAt: Date
    var createdAt = Date()
    var entryID: UUID? = nil
}
enum PersonalSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }
    static var models: [any PersistentModel.Type] { PersonalSchemaV5.models + [MeasurementRecord.self] }
    @Model final class MeasurementRecord {
        @Attribute(.unique) var id: UUID
        var data: Data
        init(_ value: BodyMeasurement) throws { id = value.id; data = try JSONEncoder().encode(value) }
    }
}
@MainActor final class MeasurementRepository {
    private let context: ModelContext
    init(container: ModelContainer) { context = ModelContext(container); context.autosaveEnabled = false }
    func all() throws -> [BodyMeasurement] {
        try context.fetch(FetchDescriptor<PersonalSchemaV6.MeasurementRecord>()).map {
            try JSONDecoder().decode(BodyMeasurement.self, from: $0.data)
        }.sorted { $0.measuredAt > $1.measuredAt }
    }
    func save(_ value: BodyMeasurement) throws {
        try saveEntry([value])
    }
    func saveEntry(_ values: [BodyMeasurement]) throws {
        guard !values.isEmpty, values.allSatisfy({ $0.value > 0 && $0.value <= 1000 && $0.measuredAt <= Date() }), Set(values.map(\.id)).count == values.count else { throw FoodError.invalidNumber }
        do {
            for value in values {
            let id = value.id
            if let old = try context.fetch(FetchDescriptor<PersonalSchemaV6.MeasurementRecord>(predicate: #Predicate { $0.id == id })).first {
                old.data = try JSONEncoder().encode(value)
            } else { context.insert(try PersonalSchemaV6.MeasurementRecord(value)) }
            }
            try context.save()
        } catch { context.rollback(); throw error }
    }
    func delete(_ id: UUID) throws {
        do {
            let records = try context.fetch(FetchDescriptor<PersonalSchemaV6.MeasurementRecord>(predicate: #Predicate { $0.id == id }))
            records.forEach { context.delete($0) }; try context.save()
        } catch { context.rollback(); throw error }
    }
}
