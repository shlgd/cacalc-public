import Foundation
import CryptoKit
import SwiftData

/// Additive migration: v1/v2 records, product drafts and goals keep their original schema.
enum PersonalSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] { PersonalSchemaV2.models + [JournalRecord.self, MealDraftRecord.self, ChoiceRecord.self] }
    @Model final class JournalRecord {
        @Attribute(.unique) var id: UUID
        var dayKey: String
        var mealKey: String
        var data: Data
        init(id: UUID, day: Day, meal: Meal, data: Data) {
            self.id = id; dayKey = day.rawValue; mealKey = meal.rawValue; self.data = data
        }
    }
    @Model final class MealDraftRecord {
        @Attribute(.unique) var key: String
        var data: Data
        init(_ data: Data) { key = "current"; self.data = data }
    }
    @Model final class ChoiceRecord {
        @Attribute(.unique) var key: String
        var phrase: String
        var productID: String
        var productData: Data
        var count: Int
        var lastUsed: Date
        init(phrase: String, product: Product, data: Data, now: Date) {
            key = phrase + "\u{1F}" + product.id; self.phrase = phrase; productID = product.id
            productData = data; count = 1; lastUsed = now
        }
    }
}

actor MealRepository {
    private let container: ModelContainer
    private var failNextSave = false
    private var failNextLoad = false
    private var memorySnapshot: (key: String, usage: [MatchHistory], history: [MatchHistory])?
    private(set) var readIssues: [StoredDataIssue] = []
    init(container: ModelContainer) { self.container = container }
    func page(for day: Day) throws -> DiaryPageData {
        try DiaryStore.loadPage(for: day, context: database())
    }
    private func database() -> ModelContext {
        let context = ModelContext(container); context.autosaveEnabled = false; return context
    }
    func injectSaveFailure() { failNextSave = true }
    func injectLoadFailure() { failNextLoad = true }
    private func save(_ db: ModelContext) throws {
        if failNextSave { failNextSave = false; throw FoodError.database("Тестовая ошибка сохранения") }
        try db.save()
    }
    func drafts() throws -> DraftCollection<MealDraft> {
        if failNextLoad { failNextLoad = false; throw FoodError.database("Тестовая ошибка чтения") }
        return try DraftStorage.all(MealDraft.self, kind: .meal, db: database())
    }
    func loadDraft() throws -> MealDraft? { try drafts().values.first }
    func persist(_ draft: MealDraft) throws {
        let db = database()
        do {
            try DraftStorage.save(draft, id: draft.id, kind: .meal, editingKey: draft.editingEntryID?.uuidString, db: db)
            try save(db)
        } catch { db.rollback(); throw error }
    }
    func discardDraft(_ id: UUID) throws {
        let db = database()
        do { try DraftStorage.close(id, kind: .meal, db: db); try save(db) }
        catch { db.rollback(); throw error }
    }
    func audioIsReferenced(_ file: String) throws -> Bool { try DraftStorage.audioIsReferenced(file, db: database()) }
    func history() throws -> [MatchHistory] { try consumptionMemory(now: Date()).history }
    private func episodeRecords(_ episodes: [UUID], db: ModelContext) throws -> [PersonalSchemaV3.JournalRecord] {
        var keys: [UUID] = []
        for episode in episodes {
            keys += try db.fetch(FetchDescriptor<PersonalSchemaV8.JournalIndex>(predicate: #Predicate {
                $0.episodeID == episode
            })).map(\.id)
        }
        return try db.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>(predicate: #Predicate { keys.contains($0.id) }))
    }
    func commit(_ draft: MealDraft, now: Date = Date()) throws {
        guard !draft.rows.isEmpty else { throw FoodError.database("Добавьте хотя бы одну позицию.") }
        if let timing = draft.timing, timing.mode == .earlier, let date = timing.selectedAt, date > now {
            throw FoodError.database("Это время ещё не наступило. Выберите «Планирую» или укажите время еды в прошлом.")
        }
        let timing = draft.timing?.confirmed(rows: draft.rows, day: draft.day, now: now)
        let validated = try draft.rows.map { original in
            var row = try original.validated()
            if let timing { row.timing = timing }
            return row
        }
        guard Set(validated.map(\.id)).count == validated.count,
              draft.editingEntryID == nil || (validated.count == 1 && validated[0].id == draft.editingEntryID) else {
            throw FoodError.database("Запись изменилась. Откройте её ещё раз; черновик сохранён.")
        }
        let db = database(), ids = validated.map(\.id)
        let existing = try db.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>(predicate: #Predicate { ids.contains($0.id) }))
        let legacy = try db.fetch(FetchDescriptor<PersonalSchema.Record>(predicate: #Predicate { ids.contains($0.id) }))
        do {
            for old in existing {
                let previous = try JSONDecoder().decode(MealRow.self, from: old.data)
                if previous.timing?.isPlanned == false, draft.timing?.isPlanned == true,
                   (draft.timing?.updatedAt ?? .distantPast) <= (previous.timing?.updatedAt ?? .distantPast) {
                    throw FoodError.database("Этот план уже подтверждён. Откройте актуальную запись перед изменением.")
                }
            }
            if try DraftStorage.completed(draft, id: draft.id, kind: .meal, db: db) { return }
            let stock = try PreparedStorage.Reconciliation(db)
            // Editing one row's episode time changes the episode, not just its label.
            if draft.editingEntryID != nil, let timing, let old = existing.first,
               let previous = try JSONDecoder().decode(MealRow.self, from: old.data).timing,
               (draft.timing != previous || old.mealKey != draft.meal.rawValue || old.dayKey != draft.day.rawValue) {
                for sibling in try episodeRecords([previous.episodeID], db: db) where !ids.contains(sibling.id) {
                    var row = try JSONDecoder().decode(MealRow.self, from: sibling.data)
                    guard row.timing?.episodeID == previous.episodeID else { continue }
                    row.timing = timing
                    if timing.isPlanned { try stock.remove(row.id) }
                    else { try stock.apply(row) }
                    sibling.dayKey = draft.day.rawValue
                    sibling.mealKey = draft.meal.rawValue
                    try StorageRevision.index(id: sibling.id, day: sibling.dayKey, row: row, db: db)
                    sibling.data = try JSONEncoder().encode(row)
                }
            }
            for row in validated {
                if row.timing?.isPlanned == true { try stock.remove(row.id) }
                else { try stock.apply(row) }
                let data = try JSONEncoder().encode(row)
                let old = existing.first { $0.id == row.id }
                let previous = try old.map { try JSONDecoder().decode(MealRow.self, from: $0.data) }
                if let old {
                    old.data = data; old.dayKey = draft.day.rawValue; old.mealKey = draft.meal.rawValue
                } else { db.insert(PersonalSchemaV3.JournalRecord(id: row.id, day: draft.day, meal: draft.meal, data: data)) }
                try StorageRevision.index(id: row.id, day: draft.day.rawValue, row: row, db: db)
                // Confirmation is an observation, not an immutable generic alias or proof of home inventory.
                if row.timing?.isPlanned != true, let product = row.product, old == nil || previous?.product?.id != product.id || previous?.food != row.food {
                    let phrase = MealMatcher.normalize(row.food), productID = product.id
                    let choice = try db.fetch(FetchDescriptor<PersonalSchemaV3.ChoiceRecord>(predicate: #Predicate {
                        $0.phrase == phrase && $0.productID == productID
                    })).first
                    let productData = try JSONEncoder().encode(product)
                    if let choice { choice.count += 1; choice.lastUsed = now; choice.productData = productData }
                    else { db.insert(PersonalSchemaV3.ChoiceRecord(phrase: phrase, product: product, data: productData, now: now)) }
                }
                if row.confirmedBasis == true, let product = row.product {
                    let key = product.id, data = try JSONEncoder().encode(product)
                    let personal = try db.fetch(FetchDescriptor<PersonalSchema.PersonalProduct>(predicate: #Predicate { $0.key == key })).first
                    if let personal { personal.data = data }
                    else { db.insert(PersonalSchema.PersonalProduct(product, data: data)) }
                }
            }
            legacy.forEach { db.delete($0) }
            try DraftStorage.finish(draft, id: draft.id, kind: .meal, db: db)
            try StorageRevision.touch("journal", db: db)
            try StorageRevision.touch("products", db: db)
            try StorageRevision.touch("prepared", db: db)
            try save(db)
        } catch { db.rollback(); throw error }
    }
    /// Atomic episode conversion. Repeated delivery observes consumed rows and does nothing.
    func consumeEpisode(_ episodeID: UUID, now: Date = Date()) throws {
        let db = database()
        do {
            let records = try episodeRecords([episodeID], db: db)
            let stock = try PreparedStorage.Reconciliation(db)
            for record in records {
                var row = try JSONDecoder().decode(MealRow.self, from: record.data)
                guard var timing = row.timing, timing.episodeID == episodeID, timing.isPlanned else { continue }
                timing.mode = .earlier; timing.selectedAt = now; timing.consumedAt = now
                timing.updatedAt = now; timing.source = "user"; row.timing = timing
                try stock.apply(row)
                record.dayKey = Day(now).rawValue
                record.data = try JSONEncoder().encode(row)
                try StorageRevision.index(id: row.id, day: record.dayKey, row: row, db: db)
            }
            try StorageRevision.touch("journal", db: db)
            try StorageRevision.touch("prepared", db: db)
            try save(db)
        } catch { db.rollback(); throw error }
    }
    /// Reassigns complete saved episodes while keeping their rows, timing and stock links intact.
    /// Legacy rows have no episode identity and are reassigned only when explicitly selected.
    func reassignMeal(_ ids: [UUID], to meal: Meal) throws {
        let requested = Set(ids)
        guard !requested.isEmpty else { throw FoodError.database("Приём пищи не найден.") }
        let values = Array(requested), db = database()
        do {
            let selectedJournal = try db.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>(predicate: #Predicate {
                values.contains($0.id)
            }))
            let selectedLegacy = try db.fetch(FetchDescriptor<PersonalSchema.Record>(predicate: #Predicate {
                values.contains($0.id)
            }))
            let found = Set(selectedJournal.map(\.id) + selectedLegacy.map(\.id))
            guard found == requested else {
                throw FoodError.database("Запись изменилась. Обновите дневник и попробуйте ещё раз.")
            }
            let episodes = Set(try selectedJournal.compactMap {
                try JSONDecoder().decode(MealRow.self, from: $0.data).timing?.episodeID
            })
            var journal = selectedJournal
            if !episodes.isEmpty {
                let selectedIDs = Set(selectedJournal.map(\.id))
                for record in try episodeRecords(Array(episodes), db: db) where !selectedIDs.contains(record.id) {
                    let row = try JSONDecoder().decode(MealRow.self, from: record.data)
                    if let episodeID = row.timing?.episodeID, episodes.contains(episodeID) { journal.append(record) }
                }
            }
            guard journal.contains(where: { $0.mealKey != meal.rawValue }) ||
                    selectedLegacy.contains(where: { $0.mealKey != meal.rawValue }) else { return }
            journal.forEach { $0.mealKey = meal.rawValue }
            selectedLegacy.forEach { $0.mealKey = meal.rawValue }
            try StorageRevision.touch("journal", db: db)
            try save(db)
        } catch { db.rollback(); throw error }
    }
    func remove(_ id: UUID) throws {
        let db = database()
        try PreparedStorage.removeUse(id, db: db)
        try db.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>(predicate: #Predicate { $0.id == id })).forEach { db.delete($0) }
        try db.fetch(FetchDescriptor<PersonalSchema.Record>(predicate: #Predicate { $0.id == id })).forEach { db.delete($0) }
        try StorageRevision.removeIndex(id, db: db)
        try StorageRevision.touch("journal", db: db)
        try StorageRevision.touch("prepared", db: db)
        do { try save(db) } catch { db.rollback(); throw error }
    }
}

/// Permanent local research archive. Events are immutable; no age/size pruning.
actor MatchingLog {
    static let shared = MatchingLog()
    let directory: URL
    private let journal: DurableEventJournal
    private let processID = UUID().uuidString
    private var sequence = 0
    init(directory: URL = URL.documentsDirectory.appendingPathComponent("DictationArchive", isDirectory: true)) {
        self.directory = directory
        self.journal = directory == URL.documentsDirectory.appendingPathComponent("DictationArchive", isDirectory: true)
            ? .shared : DurableEventJournal(path: directory.appendingPathComponent("events-v1.sqlite"))
    }
    func write(_ event: String, fields: [String: String]) throws {
        let fm = FileManager.default
        var record = fields
        sequence += 1
        record["event"] = event; record["version"] = "dictation-v2"
        record["processID"] = processID; record["sequence"] = String(sequence)
        record["time"] = record["time"] ?? Self.timestamp()
        record["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "test"
        let id = fields["eventID"].flatMap(UUID.init(uuidString:)) ?? UUID()
        record["eventID"] = id.uuidString
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if fm.fileExists(atPath: url.path) { return } // Same queued event retried after a successful write.
        try journal.append([record], stream: "meal")
    }
    func events() throws -> [[String: String]] { try journal.events(stream: "meal") }
    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    func ensureRecordingSpace() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let attributes = try fm.attributesOfFileSystem(forPath: directory.path)
        if let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < 256 * 1024 * 1024 {
            throw FoodError.database("Для записи и архива осталось меньше 256 МБ. Освободите место: старые диктовки автоматически не удаляются.")
        }
    }
    func archiveAudio(_ source: URL, dictationID: UUID) throws -> [String: String] {
        let fm = FileManager.default
        let folder = directory.appendingPathComponent("Audio", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(dictationID.uuidString + ".wav")
        func digest(_ url: URL) throws -> (count: Int, hash: String) {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var hash = SHA256(), count = 0
            while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                hash.update(data: bytes); count += bytes.count
            }
            guard count > 0 else { throw FoodError.database("Пустой файл аудио") }
            return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
        let receipt: (count: Int, hash: String)
        if fm.fileExists(atPath: target.path) {
            receipt = try digest(source)
            let archived = try digest(target)
            guard receipt == archived else { throw FoodError.database("Конфликт аудио в архиве") }
        } else {
            let partial = target.appendingPathExtension("partial")
            // A partial copy is replaceable only while the original still exists.
            guard fm.fileExists(atPath: source.path) else { throw FoodError.database("Исходная запись недоступна") }
            if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
            defer { try? fm.removeItem(at: partial) }
            try fm.copyItem(at: source, to: partial)
            receipt = try digest(partial)
            let output = try FileHandle(forWritingTo: partial)
            do { try output.synchronize(); try output.close() }
            catch { try? output.close(); throw error }
            try fm.moveItem(at: partial, to: target)
        }
        return ["audio": "Audio/" + target.lastPathComponent, "audioBytes": String(receipt.count), "audioSHA256": receipt.hash,
                "audioFormat": "WAV PCM16 mono 16000Hz"]
    }
}

extension MealRepository {
    func usage(now: Date = Date()) throws -> [MatchHistory] { try consumptionMemory(now: now).usage }
    private func consumptionMemory(now: Date) throws -> (usage: [MatchHistory], history: [MatchHistory]) {
        let db = database(), today = Day(now).rawValue
        let key = try StorageRevision.token("journal", db: db) + today
        if let memorySnapshot, memorySnapshot.key == key { return (memorySnapshot.usage, memorySnapshot.history) }
        var grouped: [String: MatchHistory] = [:], phrases: [String: MatchHistory] = [:], issues: [StoredDataIssue] = []
        func add(_ product: Product, food: String, dayKey: String) {
            guard dayKey <= today else { return }
            let date = Day(rawValue: dayKey).date
            func update(_ key: String, phrase: String, values: inout [String: MatchHistory]) {
                if var value = values[key] {
                    value.count += 1
                    if date >= value.lastUsed { value.product = product; value.lastUsed = date }
                    values[key] = value
                } else { values[key] = MatchHistory(phrase: phrase, product: product, count: 1, lastUsed: date) }
            }
            update(product.id, phrase: "", values: &grouped)
            let phrase = MealMatcher.normalize(food)
            update(phrase + "\u{1F}" + product.id, phrase: phrase, values: &phrases)
        }
        let records = try db.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>())
        let ids = Set(records.map(\.id))
        for record in records {
            do {
                let row = try JSONDecoder().decode(MealRow.self, from: record.data)
                if row.timing?.isPlanned != true, let product = row.product { add(product, food: row.food, dayKey: record.dayKey) }
            } catch { issues.append(.init(id: record.id.uuidString, message: "Память употребления неполна: запись \(record.id) не прочитана. Данные сохранены.")) }
        }
        for record in try db.fetch(FetchDescriptor<PersonalSchema.Record>()) where !ids.contains(record.id) {
            do { let product = try JSONDecoder().decode(Product.self, from: record.productData); add(product, food: product.name, dayKey: record.dayKey) }
            catch { issues.append(.init(id: record.id.uuidString, message: "Память употребления неполна: старая запись \(record.id) не прочитана.")) }
        }
        let usage = grouped.values.sorted { $0.count == $1.count ? $0.product.id < $1.product.id : $0.count > $1.count }
        let history = Array(phrases.values.sorted { $0.lastUsed > $1.lastUsed }.prefix(300))
        readIssues = issues; memorySnapshot = (key, usage, history)
        return (usage, history)
    }
}
