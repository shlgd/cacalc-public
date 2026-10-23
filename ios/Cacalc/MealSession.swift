import Foundation
import Observation
import SwiftUI

@MainActor @Observable final class MealSession {
    var drafts: [MealDraft] = []
    var draft: MealDraft?
    var showing = false
    var busy = false
    var processingTitle = "Разбираю продукты"
    struct LiveProgress: Equatable {
        var title: String
        var phrase: String = ""
        var working = false
        var rows: [MealRow] = []
    }
    private var emptyLiveSlotID = UUID()
    var liveInputID: UUID { liveSlotOwner == draft?.dictationID ? (liveSlotIDs.first ?? emptyLiveSlotID) : emptyLiveSlotID }
    @ObservationIgnored private var liveSlotOwner: UUID?
    @ObservationIgnored private var liveSlotIDs: [UUID] = []
    func showLiveText(_ text: String, working: Bool = false) {
        if liveSlotOwner != draft?.dictationID {
            liveSlotOwner = draft?.dictationID; liveSlotIDs = []
        }
        var preview = LiveMealParser.preview(text)
        while liveSlotIDs.count < preview.rows.count { liveSlotIDs.append(liveSlotIDs.isEmpty ? emptyLiveSlotID : UUID()) }
        for index in preview.rows.indices { preview.rows[index].id = liveSlotIDs[index] }
        let title = working && !preview.rows.isEmpty ? "Подбираю карточку" : preview.title
        if liveProgress?.title != title {
            log("liveUIState", fields: ["title": title, "pendingCount": String(preview.rows.count)])
        }
        liveProgress = LiveProgress(title: title, phrase: text, working: working, rows: preview.rows)
    }
    var liveProgress: LiveProgress?
    var voiceDeletingRows: Set<UUID> = []
    @ObservationIgnored private var liveMatching: Task<Void, Never>?
    /// Test gate exercises real async ownership without slowing production matching.
    @ObservationIgnored var beforeLiveMatching: (@MainActor () async -> Void)?
    func waitForLiveMatching() async { await liveMatching?.value }
    private func catalogueSupported(_ candidates: [ProductCandidate]) -> [ProductCandidate] {
        candidates.filter { ($0.evidence?.recognizedCoverage ?? 0) > 0 }
    }
    private func enqueueLiveMatching(_ rows: [MealRow], owner: UUID) {
        guard !rows.isEmpty, draft?.id == owner else { return }
        var requests: [MealRow] = []
        for row in rows {
            guard let i = draft?.rows.firstIndex(where: { $0.id == row.id && $0.matchingPending == true }) else { continue }
            let revision = draft?.rows[i].matchingRevision ?? UUID()
            draft?.rows[i].matchingRevision = revision
            draft?.rows[i].matchingOperationID = UUID()
            requests.append(draft!.rows[i])
        }
        guard !requests.isEmpty else { return }
        persistLater()
        let previous = liveMatching
        liveMatching = Task { [requests] in
            await previous?.value
            for original in requests {
                await beforeLiveMatching?()
                guard draft?.id == owner,
                      draft?.rows.contains(where: { ownsMatching($0, original) }) == true else { continue }
                do {
                    let pool = try await prepareCandidates(original.food, preparedOnly: original.unit == .portion || original.requestedPreparedPortions != nil)
                    let lexical = await Task.detached { pool.index.rank(original.food, history: pool.history, usage: pool.usage) }.value
                    let options: [ProductCandidate]
                    if MealMatcher.suggestion(lexical) != nil {
                        options = lexical
                        log("semanticSearch", fields: ["traceID": pool.traceID, "status": "skipped:unambiguous-lexical"])
                    } else {
                        let semantic = await semanticScorer(original.food, pool.index.products)
                        log("semanticSearch", fields: ["traceID": pool.traceID, "rowID": original.id.uuidString, "draftID": owner.uuidString,
                            "status": semantic.status, "seconds": String(semantic.seconds), "truncated": String(semantic.truncated)])
                        let scored = await Task.detached { pool.index.rank(original.food, history: pool.history, usage: pool.usage, semantic: semantic.scores) }.value
                        options = catalogueSupported(scored)
                    }
                    guard draft?.id == owner,
                          let i = draft?.rows.firstIndex(where: { ownsMatching($0, original) }) else { continue }
                    // Apply only matching fields: concurrent weight edits stay intact.
                    draft?.rows[i].matchingPending = nil
                    draft?.rows[i].matchingOperationID = nil
                    draft?.rows[i].matchTraceID = pool.traceID
                    draft?.rows[i].matchContextIDs = pool.products.map(\.id)
                    draft?.rows[i].matchOptions = Array(options.prefix(10))
                    if let product = MealMatcher.suggestion(options), pool.completeCatalog {
                        draft?.rows[i].product = product
                        draft?.rows[i].suggested = true
                        let existingAttention = draft?.rows[i].matchAttention
                        draft?.rows[i].matchAttention = existingAttention == "Проверьте исправление в диктовке" ? existingAttention : original.matchAttention
                    } else {
                        draft?.rows[i].product = options.first.flatMap { $0.score >= 60 ? $0.product : nil }
                        draft?.rows[i].matchAttention = options.isEmpty ? "Продукт не найден" : "Проверьте выбор продукта"
                    }
                    if var resolved = draft?.rows[i] {
                        resolvePreparedPortion(&resolved)
                        draft?.rows[i] = resolved
                    }
                    candidates[original.id] = Array(options.prefix(10))
                    log("ranking", row: draft?.rows[i], fields: ["mode": "live-local",
                        "traceID": pool.traceID, "candidates": json(options),
                        "selectionDecision": pool.completeCatalog ? MealMatcher.selectionReason(options) : "catalog-incomplete",
                        "winnerOutsideContext": String(options.first.map { !Set(pool.products.map(\.id)).contains($0.id) } ?? false)])
                    changed()
                    try await flush()
                } catch {
                    guard draft?.id == owner,
                          let i = draft?.rows.firstIndex(where: { ownsMatching($0, original) }) else { continue }
                    draft?.rows[i].matchingPending = nil
                    draft?.rows[i].matchingOperationID = nil
                    draft?.rows[i].matchAttention = "Не удалось подобрать продукт"
                    log("liveMatchingFailed", row: draft?.rows[i], fields: ["error": error.localizedDescription])
                    changed()
                }
            }
        }
    }
    private func ownsMatching(_ current: MealRow, _ request: MealRow) -> Bool {
        current.id == request.id && current.food == request.food && current.matchingPending == true
            && current.matchingRevision == request.matchingRevision && current.matchingOperationID == request.matchingOperationID
    }
    func backupDaily() async {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              !ProcessInfo.processInfo.arguments.contains("--meal-ui-testing") else { return }
        let storeURL = URL.applicationSupportDirectory.appendingPathComponent("default.store")
        let root = URL.documentsDirectory.appendingPathComponent("DailyBackups", isDirectory: true)
        let day = Day(Date()).rawValue
        do {
            let target = try await Task.detached(priority: .utility) {
                try DailyStoreBackup.create(store: storeURL, root: root, day: day)
            }.value
            if let target { log("dailyBackupCreated", fields: ["day": day, "directory": target.lastPathComponent]); try await flushLog() }
        } catch {
            diagnosticError = "Не удалось сохранить резервную копию: " + error.localizedDescription
            log("dailyBackupFailed", fields: ["day": day, "error": error.localizedDescription])
        }
    }
    var saving = false
    var error: String?
    var candidates: [UUID: [ProductCandidate]] = [:]
    var diagnosticError: String?
    var sortedRows: [MealRow] {
        (draft?.rows ?? []).enumerated().sorted {
            $0.element.requiresAttention == $1.element.requiresAttention ? $0.offset < $1.offset : $0.element.requiresAttention
        }.map(\.element)
    }
    @ObservationIgnored private var loggedCatalogFingerprint: String?
    private typealias QueuedEvent = MealArchiveEvent
    @ObservationIgnored private var logQueue: [QueuedEvent] = []
    @ObservationIgnored private var logTask: Task<Void, Never>?
    func log(_ event: String, row: MealRow? = nil, fields: [String: String] = [:]) {
        var values = fields
        if values["draftID"] == nil { values["draftID"] = draft?.id.uuidString }
        if values["rowID"] == nil { values["rowID"] = row?.id.uuidString }
        if values["traceID"] == nil { values["traceID"] = row?.matchTraceID }
        if values["dictationID"] == nil { values["dictationID"] = (row?.dictationID ?? draft?.dictationID)?.uuidString }
        values["eventID"] = UUID().uuidString; values["time"] = MatchingLog.timestamp()
        #if os(iOS)
        UsageTelemetry.shared.event("meal." + event, values.filter {
            ["draftID", "rowID", "traceID", "dictationID", "eventID"].contains($0.key)
        }.reduce(into: [String: String]()) { result, pair in
            result[pair.key == "eventID" ? "domainEventID" : pair.key] = pair.value
        })
        #endif
        logQueue.append(QueuedEvent(name: event, fields: values))
        guard logTask == nil else { return }
        logTask = Task {
            do { try await drainLog() }
            catch { diagnosticError = "Архив диктовки не сохранён: " + error.localizedDescription }
            logTask = nil
        }
    }
    private func drainLog() async throws {
        while let event = logQueue.first {
            try await diagnosticLog.write(event.name, fields: event.fields)
            if logQueue.first?.fields["eventID"] == event.fields["eventID"] { logQueue.removeFirst() }
        }
        diagnosticError = nil
    }
    func flushLog() async throws {
        await logTask?.value
        do { try await drainLog() }
        catch { diagnosticError = "Архив диктовки не сохранён: " + error.localizedDescription; throw error }
    }
    private func json<T: Encodable>(_ value: T) -> String {
        do { return String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        catch { diagnosticError = "Не удалось подготовить архив: " + error.localizedDescription; return "serialization-error" }
    }
    func prepareArchive() async throws { try await diagnosticLog.ensureRecordingSpace() }
    func preserveAudio(_ file: String, owner: MealDraft) async throws {
        let id = owner.dictationID ?? UUID(uuidString: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent) ?? owner.id
        let fields = try await diagnosticLog.archiveAudio(VoiceFiles.url(file), dictationID: id)
        log("audioArchived", fields: fields.merging(["draftID": owner.id.uuidString, "dictationID": id.uuidString]) { _, new in new })
        try await flushLog()
    }
    var hasPendingDictation: Bool {
        guard let draft else { return false }
        if draft.liveMode == true, draft.audioFile != nil { return true }
        if draft.livePendingText?.isEmpty == false { return true }
        return (!draft.transcript.isEmpty && draft.appliedTranscript != draft.transcript && draft.dictationPreviewOnly != true)
            || (draft.audioFile != nil && draft.transcript.isEmpty)
    }
    var canCommit: Bool {
        guard !saving, !busy, !hasPendingDictation, let rows = draft?.rows, !rows.isEmpty else { return false }
        return rows.allSatisfy { $0.matchingPending != true && (try? $0.validated()) != nil }
    }
    @ObservationIgnored private let diagnosticLog: MatchingLog
    @ObservationIgnored let repository: MealRepository
    @ObservationIgnored private let store: DiaryStore
    @ObservationIgnored private let api: MealAPI
    @ObservationIgnored private let semanticScorer: @Sendable (String, [Product]) async -> SemanticProductSearch.Result
    @ObservationIgnored private let keyProvider: () throws -> String?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var loading: Task<DraftCollection<MealDraft>, Error>?
    @ObservationIgnored private var loadingID: UUID?
    @ObservationIgnored private var writer: DraftWriter<MealDraft>!
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var audioArchiving: Task<Void, Error>?
    @ObservationIgnored private var pendingAudioArchive: (String, MealDraft)?
    init(store: DiaryStore, diagnosticLog: MatchingLog = .shared, api: MealAPI = MealAPI(), keyProvider: @escaping () throws -> String? = { try MealAPIKey.read() }, semanticScorer: @escaping @Sendable (String, [Product]) async -> SemanticProductSearch.Result = { text, products in await SemanticProductSearch.shared.scores(text, products: products) }) {
        self.semanticScorer = semanticScorer
        self.diagnosticLog = diagnosticLog
        self.store = store; self.api = api; self.keyProvider = keyProvider
        repository = MealRepository(container: store.container)
        let persistence = repository
        writer = DraftWriter(write: { value in try await persistence.persist(value) },
            failed: { [weak self] error in self?.error = "Черновик пока не сохранён на диск. " + error.localizedDescription })
    }
    func load() async {
        guard !loaded else { return }
        if loading == nil { loadingID = UUID(); loading = Task { try await repository.drafts() } }
        let requestID = loadingID
        let task = loading!
        defer { if loadingID == requestID { loading = nil; loadingID = nil } }
        do {
            let collection = try await task.value
            let value = collection.values.first
            if !loaded {
                drafts = collection.values; draft = value; loaded = true
                if !collection.issues.isEmpty { error = collection.issues.map(\.message).joined(separator: "\n") }
                if let savedEvents = value?.auditPending { logQueue += savedEvents }
                draft?.auditPending = nil
                if let value {
                    log("draftRecovered", fields: ["snapshot": json(value)])
                    enqueueLiveMatching(value.rows.filter { $0.matchingPending == true }, owner: value.id)
                }
                // Repair only the exact machine-generated no-food marker from build 132.
                if value?.pendingResponse?.trimmingCharacters(in: .whitespacesAndNewlines) == "-|?" {
                    draft?.rows.removeAll { $0.food == "-" && $0.quantity.isEmpty && $0.product == nil }
                    if draft?.rows.count != value?.rows.count { changed(); try await flush() }
                }
            }
        }
        catch { self.error = "Не удалось прочитать черновик. Данные сохранены. " + error.localizedDescription }
    }
    func resume(_ id: UUID) async {
        guard !saving, !busy else { return }
        await load()
        do {
            try await flush()
            drafts = try await repository.drafts().values
            guard let value = drafts.first(where: { $0.id == id }) else { throw FoodError.database("Черновик не найден.") }
            draft = value; candidates = [:]; liveProgress = nil
            if let events = value.auditPending { logQueue += events.filter { saved in !logQueue.contains { $0.fields["eventID"] == saved.fields["eventID"] } } }
            enqueueLiveMatching(value.rows.filter { $0.matchingPending == true }, owner: value.id)
            showing = true
        } catch { self.error = error.localizedDescription }
    }
    func begin(day: Day, meal: Meal? = nil, item: DiaryItem? = nil, now: Date = Date()) async {
        guard !saving, !busy else { return }
        await load()
        guard loaded else { return }
        do {
            try await flush()
            drafts = try await repository.drafts().values
            if let item, let existing = drafts.first(where: { $0.editingEntryID == item.id }) {
                draft = existing
            } else {
                var value = MealDraft(day: item?.day ?? day, meal: try item?.meal ?? meal ?? suggestedMeal(for: day, at: now))
                value.timing = MealTiming(mode: day > store.today ? .planned : .now, startedAt: now, selectedAt: day > store.today ? day.date : nil)
                if let item { value.rows = [item.row]; value.editingEntryID = item.id; value.timing = item.row.timing }
                draft = value
                log("draftOpened", fields: ["snapshot": json(value),
                    "suggestionRule": item == nil && meal == nil ? MealEntrySuggestion.ruleVersion : "explicit"])
                changed()
                try await flush()
            }
            candidates = [:]; liveProgress = nil; showing = true
        } catch { self.error = error.localizedDescription }
    }
    private func suggestedMeal(for day: Day, at now: Date) throws -> Meal {
        let page = try store.page(for: day)
        let defaults = UserDefaults.standard
        var wake: Date? = nil
        #if os(iOS)
        wake = HealthSleep.shared.wake
        #endif
        let proposed = MealEntrySuggestion.choose(page: page, day: day, now: now,
            intervalHours: defaults.object(forKey: "planner.intervalHours") as? Double ?? 4,
            bedtimeHour: defaults.object(forKey: "planner.bedtimeHour") as? Int ?? 23,
            history: store.mealHistory, wakeTime: wake)
        return proposed
    }
    func changed() {
        if draft?.editingEntryID == nil, let rows = draft?.rows {
            let now = Date()
            for i in rows.indices where rows[i].addedAt == nil { draft?.rows[i].addedAt = now }
        }
        draft?.revision = UUID()
        persistLater()
    }
    private func draftWithOutbox() -> MealDraft? {
        guard var value = draft else { return nil }
        let events = logQueue.filter { $0.fields["draftID"] == value.id.uuidString }
        value.auditPending = events.isEmpty ? nil : events
        return value
    }
    private func persistLater() {
        guard let value = draftWithOutbox() else { return }
        if let i = drafts.firstIndex(where: { $0.id == value.id }) { drafts[i] = value }
        else { drafts.insert(value, at: 0) }
        writer.submit(value, id: value.id)
    }
    func flush() async throws {
        if audioArchiving == nil, let (file, owner) = pendingAudioArchive {
            audioArchiving = Task { try await preserveAudio(file, owner: owner) }
        }
        do { try await audioArchiving?.value }
        catch { audioArchiving = nil; throw error }
        audioArchiving = nil; pendingAudioArchive = nil
        let value = draftWithOutbox()
        if let value { writer.submit(value, id: value.id) }
        try await writer.flush()
        try await flushLog()
        if value?.auditPending?.isEmpty == false, let latest = draftWithOutbox() {
            writer.submit(latest, id: latest.id)
            try await writer.flush()
        }
    }
    func updateRow(_ id: UUID, automaticQuantity: Bool = false, _ edit: (inout MealRow) -> Void) {
        guard !saving, let index = draft?.rows.firstIndex(where: { $0.id == id }) else { return }
        let original = draft!.rows[index]
        var updated = original; edit(&updated)
        guard updated != original else { return }
        if updated.food != original.food && updated.manualNutrition == nil {
            updated.matchingPending = nil
            updated.matchingRevision = UUID(); updated.matchingOperationID = nil
            updated.product = nil; updated.matchAttention = "Название изменено — выберите продукт"
            updated.matchOptions = nil; candidates[id] = nil
            log("renameMention", row: original, fields: ["before": original.food, "after": updated.food])
        }
        if !automaticQuantity && (updated.quantity != original.quantity || updated.unit != original.unit) {
            updated.requestedPreparedPortions = nil
        }
        updated.snapshot = nil
        log("rowEdited", row: original, fields: ["before": json(original), "after": json(updated)])
        draft?.rows[index] = updated; changed()
    }
    func saveQuickEntry(_ row: MealRow, owner: UUID) async throws {
        guard !saving, draft?.id == owner else { throw FoodError.database("Приём пищи уже закрыт.") }
        let value = try row.validated()
        guard value.manualNutrition != nil, value.product == nil else { throw FoodError.missingNutrition }
        if let index = draft?.rows.firstIndex(where: { $0.id == value.id }) {
            let old = draft!.rows[index]
            draft?.rows[index] = value
            log("quickEntryEdited", row: value, fields: ["before": json(old), "after": json(value)])
        } else {
            guard draft?.editingEntryID == nil else { throw FoodError.database("Откройте новый приём пищи.") }
            draft?.rows.append(value)
            log("quickEntryAdded", row: value, fields: ["snapshot": json(value)])
        }
        changed()
        try await flush()
    }
    func addCombination(_ rows: [MealRow], combinationID: UUID, owner: UUID?) async throws {
        await load()
        guard loaded, !saving, !busy, draft?.id == owner, draft?.editingEntryID == nil else {
            throw FoodError.database("Текущий ввод изменился. Откройте сочетание заново после завершения записи.")
        }
        guard !rows.isEmpty, Set(rows.map(\.id)).count == rows.count,
              Set(draft?.rows.map(\.id) ?? []).isDisjoint(with: rows.map(\.id)) else {
            throw FoodError.database("Это добавление уже выполнено.")
        }
        _ = try rows.map { try $0.validated() }
        if draft == nil {
            let day = store.selectedDay
            let now = Date()
            let proposed = try suggestedMeal(for: day, at: now)
            draft = MealDraft(day: day, meal: proposed)
            draft?.timing = MealTiming(mode: day > store.today ? .planned : .now, startedAt: now, selectedAt: day > store.today ? day.date : nil)
        }
        draft?.rows.append(contentsOf: rows)
        log("combinationAdded", fields: ["combinationID": combinationID.uuidString, "rows": json(rows)])
        changed()
        // Keep the visible draft on persistence failure so a retry cannot silently add it twice.
        showing = true
        try await flush()
    }
    func addManual(_ product: Product? = nil, name: String = "") {
        guard !saving, draft?.editingEntryID == nil else { return }
        let unit = product.flatMap { FoodUnit(rawValue: $0.basis.rawValue) }
        let row = MealRow(food: product?.name ?? name, unit: unit, product: product)
        draft?.rows.append(row); log("manualRowAdded", row: row, fields: ["snapshot": json(row)]); changed()
    }
    func removeRows(_ ids: Set<UUID>) {
        guard !saving else { return }
        for row in draft?.rows.filter({ ids.contains($0.id) }) ?? [] {
            log("rowDeleted", row: row, fields: ["before": json(row)])
        }
        draft?.rows.removeAll { ids.contains($0.id) }; changed()
    }
    func choose(_ product: Product?, for id: UUID) {
        if let i = draft?.rows.firstIndex(where: { $0.id == id }) { draft?.rows[i].matchingPending = nil }
        if let old = draft?.rows.first(where: { $0.id == id }) {
            log("choice", row: old, fields: ["before": old.product?.id ?? "", "after": product?.id ?? "", "food": old.food,
                "inContext": String(product.map { old.matchContextIDs?.contains($0.id) == true } ?? false),
                "candidateRank": String(old.matchOptions?.firstIndex { $0.id == product?.id }.map { $0 + 1 } ?? 0)])
        }
        guard let old = draft?.rows.first(where: { $0.id == id }) else { return }
        if (old.unit == .portion || old.requestedPreparedPortions != nil), product != nil, product?.preparedBatchID == nil {
            error = "Для порции выберите приготовленное блюдо или укажите вес в граммах."
            return
        }
        updateRow(id, automaticQuantity: true) { row in
            row.product = product; row.suggested = false; row.confirmedBasis = nil; row.matchAttention = nil
            resolvePreparedPortion(&row)
        }
    }
    /// Resolve a spoken serving into a visible gram snapshot. This never consumes stock.
    private func resolvePreparedPortion(_ row: inout MealRow) {
        guard let count = row.requestedPreparedPortions ?? (row.unit == .portion ? row.amount : nil) else { return }
        row.requestedPreparedPortions = count
        row.batchPortions = count
        row.snapshot = nil
        do {
            guard let id = row.product?.preparedBatchID,
                  let stock = try PreparedRepository(container: store.container).stocks().first(where: { $0.id == id && $0.active }),
                  let grams = stock.nextGrams, count > 0, count <= 1000 else {
                row.quantity = Numbers.string(count); row.unit = .portion
                row.product = nil
                row.matchAttention = "Выберите приготовленное блюдо"
                return
            }
            // Persist up to the quantity parser's 18 decimal places; UI rounds separately.
            var exact = grams * count, representable = Decimal()
            NSDecimalRound(&representable, &exact, 18, .plain)
            guard representable > 0, representable <= 1_000_000 else { throw FoodError.invalidNumber }
            row.quantity = Numbers.string(representable)
            row.unit = .g
            if count > stock.portions { row.matchAttention = "Порций больше, чем осталось — проверьте количество" }
            log("preparedPortionResolved", row: row, fields: ["batchID": id.uuidString,
                "requestedPortions": NSDecimalNumber(decimal: count).stringValue,
                "remainingGrams": NSDecimalNumber(decimal: stock.grams).stringValue,
                "remainingPortions": NSDecimalNumber(decimal: stock.portions).stringValue,
                "resolvedGrams": row.quantity])
        } catch {
            row.quantity = Numbers.string(count); row.unit = .portion; row.product = nil
            row.matchAttention = "Не удалось рассчитать порцию"
            log("preparedPortionFailed", row: row, fields: ["error": error.localizedDescription])
        }
    }
    private struct CandidatePool: Sendable {
        var history: [MatchHistory] = []
        var usage: [MatchHistory] = []
        var products: [Product] = []
        var reasons: [String: [String]] = [:]
        var index = SearchIndex(products: [])
        var completeCatalog = true
        var traceID = UUID().uuidString
    }
    private func prepareCandidates(_ text: String, preparedOnly: Bool = false) async throws -> CandidatePool {
        let prepareStarted = Date()
        let filtered = FoodWordFilter.apply(MealMatcher.normalize(text), search: true)
        log("searchFilter", fields: ["source": text, "filtered": filtered.text,
                                    "removed": json(filtered.removed), "version": "1"])
        let ownerID = draft?.id.uuidString ?? ""
        let expectedOwner = draft?.id
        let dictationID = draft?.dictationID?.uuidString ?? ""
        let excluded = Set(draft?.rows.compactMap { $0.product?.id } ?? [])
        var pool = CandidatePool()
        pool.history = try await repository.history()
        let usage = try await repository.usage()
        pool.usage = usage
        let issues = await repository.readIssues
        guard draft?.id == expectedOwner, !Task.isCancelled else { throw CancellationError() }
        if !issues.isEmpty { diagnosticError = issues.map(\.message).joined(separator: "\n") }
        var products: [Product]
        do {
            pool.index = try await store.productRepository.searchIndex(store.catalog)
            products = pool.index.products
        }
        catch {
            let hidden = try await store.productRepository.hiddenIDs()
            products = try await store.productRepository.search("", limit: nil).filter { !hidden.contains($0.id) }
            pool.completeCatalog = false
            let fallbackProducts = products
            pool.index = await Task.detached { SearchIndex(products: fallbackProducts) }.value
            log("catalogUnavailable", fields: ["message": error.localizedDescription])
        }
        if preparedOnly {
            products = products.filter { $0.preparedBatchID != nil }
            pool.index = SearchIndex(products: products)
        }
        guard draft?.id == expectedOwner, !Task.isCancelled else { throw CancellationError() }
        let recent = Set(usage.filter { $0.lastUsed >= Calendar.current.startOfDay(for: Date()).addingTimeInterval(-6 * 86400) }.map { $0.product.id })
        let frequent = Set(usage.prefix(30).map { $0.product.id })
        let significant = MealMatcher.searchWords(text)
        for index in products.indices {
            let product = products[index]
            guard !excluded.contains(product.id) else { continue }
            var reasons: [String] = []
            if product.preparedBatchID != nil { reasons.append("prepared_batch_active") }
            if recent.contains(product.id) { reasons.append("diary:last7days") }
            if frequent.contains(product.id) { reasons.append("diary:top30") }
            let common = pool.index.terms[index].intersection(significant).sorted()
            if !common.isEmpty { reasons.append("transcript:" + common.joined(separator: ",")) }
            if !reasons.isEmpty { pool.products.append(product); pool.reasons[product.id] = reasons }
        }
        if loggedCatalogFingerprint != pool.index.fingerprint {
            log("searchCatalog", fields: ["fingerprint": pool.index.fingerprint, "products": json(products)])
            loggedCatalogFingerprint = pool.index.fingerprint
        }
        let detail = pool.products.map { ["id": $0.id, "reasons": pool.reasons[$0.id]?.joined(separator: ";") ?? ""] }
        log("context", fields: ["draftID": ownerID, "dictationID": dictationID, "traceID": pool.traceID, "transcript": text,
            "prepareMilliseconds": String(Date().timeIntervalSince(prepareStarted) * 1000),
            "catalogComplete": String(pool.completeCatalog), "catalogFingerprint": pool.index.fingerprint,
            "excludedIDs": excluded.sorted().joined(separator: ","),
            "products": String(decoding: try JSONEncoder().encode(detail), as: UTF8.self),
            "usage": String(decoding: try JSONEncoder().encode(usage.map { ["id": $0.product.id, "count": String($0.count), "lastDay": Day($0.lastUsed).rawValue] }), as: UTF8.self)])
        return pool
    }
    func matches(_ phrase: String, preparedOnly: Bool = false) async throws -> [ProductCandidate] {
        let pool = try await prepareCandidates(phrase, preparedOnly: preparedOnly)
        let semantic = await semanticScorer(phrase, pool.index.products)
        let scored = await Task.detached { pool.index.rank(phrase, history: pool.history, usage: pool.usage, semantic: semantic.scores) }.value
        return catalogueSupported(scored)
    }
    /// Each accepted audio range is checkpointed together with its rows. Replaying
    /// after a restart never adds the same range twice; matching cannot own the mic.
    @ObservationIgnored private var pairLexicon: MealPairParser.Lexicon?
    @ObservationIgnored private var pairLexiconFile: String?
    @ObservationIgnored private var pairSearchIndex: SearchIndex?
    @ObservationIgnored private var liveIdentityMemory = LiveIdentityMemory()
    @ObservationIgnored private var identityProducts: [Product] = []
    @discardableResult
    func liveOperation(file: String, renew: Bool = false) -> DraftOperation? {
        guard draft?.audioFile == file else { return nil }
        if renew || draft?.liveOperationID == nil || draft?.liveRevision == nil {
            draft?.liveOperationID = UUID(); draft?.liveRevision = UUID()
            persistLater()
        }
        guard let value = draft, let revision = value.liveRevision, let operationID = value.liveOperationID else { return nil }
        return DraftOperation(draftID: value.id, revision: revision, operationID: operationID)
    }
    func ownsLive(_ request: DraftOperation, file: String) -> Bool {
        !Task.isCancelled && draft?.id == request.draftID && draft?.audioFile == file
            && draft?.liveRevision == request.revision && draft?.liveOperationID == request.operationID
    }
    private func parseLivePairs(_ text: String, file: String, final: Bool = false) async throws -> LiveMealParser.Result {
        guard let request = liveOperation(file: file) else { throw CancellationError() }
        if pairLexiconFile != file || pairLexicon == nil {
            let index = try await store.productRepository.searchIndex(store.catalog)
            guard ownsLive(request, file: file) else { throw CancellationError() }
            pairLexicon = MealPairParser.Lexicon(index: index)
            pairLexiconFile = file
            pairSearchIndex = index
            identityProducts = index.products
            liveIdentityMemory.reset()
            log("pairCatalog", fields: ["fingerprint": index.fingerprint, "products": String(index.products.count)])
        }
        let lexicon = pairLexicon!
        let resolved = liveIdentityMemory.resolve(text, products: identityProducts)
        if resolved != text {
            log("liveIdentityRestored", fields: ["source": text, "resolved": resolved,
                "reason": "previous-exact-identity-damaged-suffix", "version": "1"])
        }
        let started = Date()
        let output = await Task.detached { MealPairParser.analyze(resolved, lexicon: lexicon, final: final) }.value
        guard ownsLive(request, file: file) else { throw CancellationError() }
        log("pairAnalysis", fields: ["trace": json(output.trace), "rows": json(output.result.rows),
            "pending": output.result.pending, "milliseconds": String(Date().timeIntervalSince(started) * 1000),
            "final": String(final)])
        return output.result
    }

    private func filteredLiveSpeech(_ text: String) -> String {
        guard let phrase = MealSpeechPhraseFilter.rejectedPhrase(text) else { return text }
        log("asrPhraseFiltered", fields: ["source": text, "phrase": phrase,
            "reason": "observed-standalone-noise-phrase", "filterVersion": "1"])
        return ""
    }

    private func hasExplicitIdentityCorrection(_ text: String) -> Bool {
        let markers: Set<String> = ["нет", "вместо", "вернее", "точнее"]
        return !markers.isDisjoint(with: Set(MealMatcher.normalize(text).split(separator: " ").map(String.init)))
    }

    /// A later ASR pass may switch language on the same audio window. Preserve a
    /// catalogue-backed identity when its replacement has no lexical evidence;
    /// a different well-supported product or an explicit correction still wins.
    private func strongLexicalProduct(_ food: String) -> Product? {
        guard let first = pairSearchIndex?.rank(food, history: []).first,
              first.score >= 90,
              (first.evidence?.recognizedCoverage ?? 0) >= 0.95,
              first.evidence?.missing.isEmpty == true,
              first.evidence?.conflicts.isEmpty == true
        else { return nil }
        return first.product
    }

    func acceptLiveHypothesis(_ text: String, owner: UUID, file: String, operation: DraftOperation? = nil) async throws {
        if let operation, !ownsLive(operation, file: file) { return }
        guard draft?.id == owner, draft?.audioFile == file, !Task.isCancelled else { return }
        let combined = [draft?.livePendingText ?? "", MealVoiceCommand.preview(filteredLiveSpeech(text))].filter { !$0.isEmpty }.joined(separator: " ")
        let parsed = try await parseLivePairs(combined, file: file)
        let previousCount = draft?.liveSemanticRows?.count ?? 0
        // A partial hypothesis may temporarily lose its ending. Keep already
        // filled positions revisable instead of removing them on every ASR pass.
        guard parsed.rows.count >= previousCount else { return }
        let matching = reconcileLiveSemanticRows(parsed.rows,
            allowWeakIdentityReplacement: hasExplicitIdentityCorrection(combined))
        showLiveText(parsed.pending)
        log("liveSemanticHypothesis", fields: ["text": combined, "rows": json(parsed.rows),
            "pending": parsed.pending, "matchingCount": String(matching.count)])
        draft?.liveRevision = UUID()
        changed()
        try await flush()
        guard draft?.id == owner, draft?.audioFile == file else { return }
        enqueueLiveMatching(matching, owner: owner)
    }

    private func reconcileLiveSemanticRows(_ proposals: [MealRow], allowWeakIdentityReplacement: Bool = false) -> [MealRow] {
        let previous = draft?.liveSemanticRows ?? []
        var snapshots: [MealRow] = []
        var matching: [MealRow] = []
        // Match unchanged identities first, so insertion before an existing food
        // cannot move a manual quantity onto another food. Repeated foods use order.
        var correspondence: [Int: Int] = [:]
        var used = Set<Int>()
        for (index, proposal) in proposals.enumerated() {
            if let old = previous.indices.first(where: { !used.contains($0) && previous[$0].food == proposal.food }) {
                correspondence[index] = old; used.insert(old)
            }
        }
        for (index, proposal) in proposals.enumerated() where correspondence[index] == nil {
            let words = MealMatcher.searchWords(proposal.food)
            if let old = previous.indices.first(where: {
                !used.contains($0) && !words.isDisjoint(with: MealMatcher.searchWords(previous[$0].food))
            }) {
                correspondence[index] = old; used.insert(old)
            } else if proposals.count == previous.count, !used.contains(index) {
                correspondence[index] = index; used.insert(index)
            }
        }
        var added = 0
        for (index, value) in proposals.enumerated() {
            var proposal = value
            proposal.dictationID = draft?.dictationID
            if let oldIndex = correspondence[index] {
                let old = previous[oldIndex]
                if old.food != proposal.food, !allowWeakIdentityReplacement,
                   let retained = strongLexicalProduct(old.food), strongLexicalProduct(proposal.food) == nil {
                    let rejected = proposal.food
                    proposal.food = old.food
                    log("liveIdentityRetained", row: old, fields: ["retained": old.food,
                        "rejected": rejected, "productID": retained.id,
                        "reason": "later-hypothesis-lost-catalog-evidence", "version": "1"])
                }
                proposal.id = old.id
                snapshots.append(proposal)
                guard let i = draft?.rows.firstIndex(where: { $0.id == old.id }),
                      var current = draft?.rows[i] else { continue }
                let nameChanged = current.food == old.food && current.food != proposal.food
                let automaticPortion = current.requestedPreparedPortions != nil
                let quantityUntouched = automaticPortion || (current.quantity == old.quantity && current.unit == old.unit)
                let portionModeChanged = quantityUntouched && (old.unit == .portion) != (proposal.unit == .portion)
                if automaticPortion && (nameChanged || old.quantity != proposal.quantity || old.unit != proposal.unit) {
                    current.requestedPreparedPortions = nil
                    current.batchPortions = nil
                    current.quantity = proposal.quantity; current.unit = proposal.unit
                    if !nameChanged && !portionModeChanged { resolvePreparedPortion(&current) }
                } else if !automaticPortion {
                    // Quantity and unit are one value: never replace only half of a manual correction.
                    if current.quantity == old.quantity && current.unit == old.unit {
                        current.quantity = proposal.quantity; current.unit = proposal.unit
                    }
                }
                if let attention = proposal.matchAttention { current.matchAttention = attention }
                if (nameChanged || portionModeChanged), current.product == nil || current.suggested {
                    current.food = proposal.food
                    current.product = nil; current.matchOptions = nil
                    current.matchingPending = true
                    current.matchingRevision = UUID(); current.matchingOperationID = nil
                    matching.append(current)
                }
                draft?.rows[i] = current
            } else {
                proposal.matchingPending = true
                if added < liveSlotIDs.count { proposal.id = liveSlotIDs[added] }
                added += 1
                snapshots.append(proposal)
                draft?.rows.append(proposal)
                matching.append(proposal)
            }
        }
        for index in previous.indices where !used.contains(index) {
            let old = previous[index]
            snapshots.append(old)
            if let i = draft?.rows.firstIndex(where: { $0.id == old.id }) {
                draft?.rows[i].matchAttention = "Проверьте: расшифровка изменилась"
            }
        }
        liveSlotIDs.removeFirst(min(added, liveSlotIDs.count))
        // The empty slot can already have become a committed row even while
        // surplus preview slots remain. Never reuse it on the next recording.
        if added > 0 && (liveSlotIDs.isEmpty || draft?.rows.contains(where: { $0.id == emptyLiveSlotID }) == true) {
            emptyLiveSlotID = UUID()
        }
        draft?.liveSemanticRows = snapshots
        return matching
    }

    @discardableResult
    func acceptLivePhrase(_ text: String, through sample: Int, owner: UUID, file: String, boundary: Bool, operation: DraftOperation? = nil) async throws -> Bool {
        if let operation, !ownsLive(operation, file: file) { return false }
        guard draft?.id == owner, draft?.audioFile == file,
              sample > (draft?.liveAudioSampleOffset ?? 0), !Task.isCancelled else { return false }
        let sourceText = [draft?.livePendingText ?? "", text].filter { !$0.isEmpty }.joined(separator: " ")
        var pendingText = draft?.livePendingText ?? ""
        var provisionalGrams = !(draft?.liveSemanticRows ?? []).isEmpty && MealPairParser.trailingBareNumber(pendingText)
        var rows: [MealRow] = []
        var stopped = false
        for part in MealVoiceCommand.parts(filteredLiveSpeech(text)) {
            switch part {
            case .text(let phrase):
                let combined = [pendingText, phrase].filter { !$0.isEmpty }.joined(separator: " ")
                var parsed = boundary ? try await parseLivePairs(combined, file: file, final: true)
                    : LiveMealParser.Result(rows: [], pending: combined)
                if boundary, parsed.rows.count < (draft?.liveSemanticRows?.count ?? 0) {
                    parsed.pending = ""
                }
                rows += reconcileLiveSemanticRows(parsed.rows,
                    allowWeakIdentityReplacement: hasExplicitIdentityCorrection(combined))
                provisionalGrams = !parsed.rows.isEmpty && parsed.pending.isEmpty && MealPairParser.trailingBareNumber(combined)
                pendingText = provisionalGrams ? combined : parsed.pending
            case .delete:
                liveIdentityMemory.reset()
                let removed = draft?.rows.last
                if let removed {
                    voiceDeletingRows.insert(removed.id)
                    defer {
                        voiceDeletingRows.remove(removed.id)
                    }
                    try await Task.sleep(for: .milliseconds(290))
                    guard draft?.id == owner, draft?.audioFile == file else { throw CancellationError() }
                    log("rowDeleted", row: removed, fields: ["before": json(removed), "source": "voice-command"])
                    withAnimation(.easeInOut(duration: 0.25)) {
                        draft?.rows.removeAll { $0.id == removed.id }
                    }
                }
                log("voiceCommand", fields: ["command": "удалить", "removedRowID": removed?.id.uuidString ?? "",
                    "clearedPending": pendingText, "throughSample": String(sample)])
                pendingText = ""
                provisionalGrams = false
                draft?.liveSemanticRows = nil
                liveSlotIDs = []
                emptyLiveSlotID = UUID()
            case .stop:
                log("voiceCommand", fields: ["command": "стоп", "throughSample": String(sample)])
                stopped = true
            }
            if stopped { break }
        }
        rows = rows.filter { candidate in draft?.rows.contains(where: { $0.id == candidate.id }) == true }
        let filtered = FoodWordFilter.apply(MealMatcher.normalize(sourceText))
        log("wordFilter", fields: ["source": sourceText, "filtered": filtered.text,
                                  "removed": json(filtered.removed), "version": "1"])
        guard draft?.id == owner, draft?.audioFile == file, !Task.isCancelled else { return false }
        log("livePhrase", fields: ["text": text, "pending": pendingText, "throughSample": String(sample), "boundary": String(boundary)])
        log("initialProposal", fields: ["mode": "live-local", "snapshot": json(rows)])
        if !provisionalGrams { draft?.liveSemanticRows = nil }
        let transcript = [draft?.transcript ?? "", text].filter { !$0.isEmpty }.joined(separator: " ")
        draft?.transcript = transcript
        draft?.livePendingText = pendingText
        draft?.livePendingIsProvisional = provisionalGrams
        if pendingText.isEmpty { liveIdentityMemory.reset() }
        draft?.liveAudioSampleOffset = sample
        draft?.liveRevision = UUID()
        changed()
        showLiveText(provisionalGrams ? "" : pendingText)
        if pendingText.isEmpty && !rows.isEmpty { liveProgress?.title = "Слушаю следующий продукт" }
        // Checkpoint phrases/cursor before async matching, so recovery never re-adds them.
        try await flush()
        guard draft?.id == owner, draft?.audioFile == file, !Task.isCancelled else { return false }
        enqueueLiveMatching(rows, owner: owner)
        return stopped
    }
    func finishLive(file: String) async throws {
        guard let original = draft, original.audioFile == file else { return }
        await waitForLiveMatching()
        guard draft?.id == original.id, draft?.audioFile == file else { return }
        try await preserveAudio(file, owner: original)
        guard draft?.id == original.id, draft?.audioFile == file else { return }
        if let pending = draft?.livePendingText, !pending.isEmpty {
            log((draft?.liveSemanticRows ?? []).isEmpty ? "liveIncomplete" : "liveProvisionalFinalized", fields: ["text": pending])
            // Deactivating live mode without a complete pair is intentionally silent.
        }
        if draft?.livePendingIsProvisional == true { draft?.livePendingText = nil }
        draft?.liveSemanticRows = nil
        let transcript = draft?.transcript
        draft?.appliedTranscript = transcript
        draft?.dictationPreviewOnly = false
        draft?.audioFile = nil
        draft?.liveOperationID = nil; draft?.liveRevision = UUID()
        liveProgress = nil
        log("liveCompleted")
        changed()
        try await flush()
        if try await !repository.audioIsReferenced(file) { VoiceFiles.remove(file) }
    }
    func resolvePendingSpeech(asFood name: String?) {
        guard !saving, let pending = draft?.livePendingText, !pending.isEmpty else { return }
        if let name {
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            addManual(name: title)
        }
        log(name == nil ? "pendingSpeechSkipped" : "pendingSpeechConfirmed", fields: ["source": pending, "food": name ?? ""])
        draft?.livePendingText = nil; liveProgress = nil; changed()
    }
    /// The selected card stays visible even when it is outside the current ranking.
    func displayedCandidates(for id: UUID) -> [ProductCandidate] {
        guard let row = draft?.rows.first(where: { $0.id == id }) else { return [] }
        let ranked = candidates[id] ?? row.matchOptions ?? []
        guard let selected = row.product else { return Array(ranked.prefix(4)) }
        let current = ranked.first(where: { $0.id == selected.id })
            ?? ProductCandidate(product: selected, score: 0, reason: "Выбранный продукт")
        return [current] + Array(ranked.filter { $0.id != selected.id }.prefix(3))
    }
    func refreshCandidates(for id: UUID) async {
        guard let owner = draft, let row = owner.rows.first(where: { $0.id == id }) else { return }
        do {
            let options = try await matches(row.food, preparedOnly: row.unit == .portion || row.requestedPreparedPortions != nil)
            guard owns(owner), draft?.rows.contains(where: { $0.id == id && $0.food == row.food }) == true else { return }
            candidates[id] = Array(options.prefix(10))
        } catch { if owns(owner) { self.error = error.localizedDescription } }
    }
    func manualSearch(_ query: String, rowID: UUID) async throws -> [Product] {
        guard let owner = draft else { throw CancellationError() }
        let row = draft?.rows.first { $0.id == rowID }
        let preparedOnly = row?.unit == .portion || row?.requestedPreparedPortions != nil
        let results = try await matches(query, preparedOnly: preparedOnly)
        let literal = try await store.search(query).filter { !preparedOnly || $0.preparedBatchID != nil }
        guard owns(owner) else { throw CancellationError() }
        var seen = Set<String>()
        let products = (literal + results.map(\.product)).filter { seen.insert($0.id).inserted }
        if let row = draft?.rows.first(where: { $0.id == rowID }) {
            log("manualSearch", row: row, fields: ["query": query, "results": products.prefix(30).map(\.id).joined(separator: ",")])
        }
        return Array(products.prefix(30))
    }
    func parse(key: String? = nil, reuseSavedResponse: Bool = false) {
        guard draft?.liveMode != true else { return }
        guard draft?.dictationPreviewOnly != true else { return }
        guard !busy, !saving, var original = draft else { return }
        guard original.editingEntryID == nil else { return }
        guard original.appliedTranscript != original.transcript else {
            error = "Этот текст уже добавлен в список. Продиктуйте следующую еду или исправьте строки."; return
        }
        original.operationID = UUID(); draft = original
        busy = true; error = nil; processingTitle = "Разбираю продукты"
        operation = Task { [original] in
            defer {
                if draft?.id == original.id && draft?.operationID == original.operationID { busy = false; operation = nil }
            }
            var applied = false
            do {
                try await flush()
                guard owns(original) else { return }
                async let prepared = prepareCandidates(original.transcript)
                let response: MealAPIResponse
                if reuseSavedResponse, let saved = original.pendingResponse {
                    log("responseReused", fields: ["response": saved, "dictationID": original.dictationID?.uuidString ?? ""])
                    response = MealAPIResponse(content: saved, seconds: original.lastRequestSeconds ?? 0,
                        inputTokens: original.inputTokens, outputTokens: original.outputTokens)
                } else {
                    guard let key = try key ?? keyProvider() else { throw MealAPIError.missingKey }
                    let archive = diagnosticLog
                    let owner = ["draftID": original.id.uuidString, "dictationID": original.dictationID?.uuidString ?? "", "attemptID": UUID().uuidString]
                    response = try await api.extract(original.transcript, key: key) { event, fields in
                        try await archive.write(event, fields: fields.merging(owner) { _, new in new })
                    }
                }
                guard owns(original) else { return }
                draft?.pendingResponse = response.content
                draft?.lastRequestSeconds = response.seconds
                draft?.inputTokens = response.inputTokens; draft?.outputTokens = response.outputTokens
                // Save the returned text before interpreting it or starting local matching.
                try await flush()
                log("modelResponse", fields: ["response": response.content, "seconds": String(response.seconds), "inputTokens": response.inputTokens.map(String.init) ?? "", "outputTokens": response.outputTokens.map(String.init) ?? "", "dictationID": original.dictationID?.uuidString ?? ""])
                try await flushLog()
                let extracted = try ExtractedMeal.decode(response.content)
                processingTitle = "Сопоставляю с каталогом"
                let pool = try await prepared
                guard owns(original) else { return }
                var selected = Set(original.rows.compactMap { $0.product?.id })
                var rows = extracted.items.map(\.row), proposed: [UUID: [ProductCandidate]] = [:]
                for index in rows.indices {
                    try Task.checkCancellation()
                    let started = Date()
                    let contextIDs = Set(pool.products.map(\.id)).subtracting(selected)
                    // Score the context first, with corpus-wide statistics; then verify global ambiguity.
                    let contextOptions = pool.index.rank(rows[index].food, history: pool.history, restrictingTo: contextIDs)
                    let options = pool.index.rank(rows[index].food, history: pool.history)
                    let available = options.filter { !selected.contains($0.id) }
                    rows[index].dictationID = original.dictationID
                    rows[index].matchTraceID = pool.traceID
                    rows[index].matchContextIDs = contextIDs.sorted()
                    rows[index].matchOptions = Array(options.prefix(10))
                    proposed[rows[index].id] = Array(options.prefix(10))
                    if let product = MealMatcher.suggestion(options), pool.completeCatalog, !selected.contains(product.id) {
                        rows[index].product = product; rows[index].suggested = true
                        selected.insert(product.id)
                    } else {
                        rows[index].matchAttention = !pool.completeCatalog ? "Базовый каталог недоступен — проверьте выбор" : options.isEmpty ? "Продукт не найден" : options.first.map { selected.contains($0.id) } == true ? "Этот продукт уже добавлен — проверьте количество" : "Проверьте, какой продукт вы имели в виду"
                        rows[index].product = available.first.flatMap { $0.score >= 60 ? $0.product : nil }
                    }
                    log("ranking", row: rows[index], fields: ["traceID": pool.traceID, "food": rows[index].food,
                        "response": response.content, "contextWinner": contextOptions.first?.id ?? "",
                        "globalWinner": options.first?.id ?? "", "winnerOutsideContext": String(options.first.map { !contextIDs.contains($0.id) } ?? false),
                        "attention": rows[index].matchAttention ?? "", "milliseconds": String(Date().timeIntervalSince(started) * 1000),
                        "candidates": String(decoding: try JSONEncoder().encode(options), as: UTF8.self)])

                }
                guard owns(original) else { return }
                log("initialProposal", fields: ["snapshot": json(rows), "response": response.content, "dictationID": original.dictationID?.uuidString ?? "", "draftID": original.id.uuidString])
                draft?.rows += rows
                candidates.merge(proposed) { _, new in new }
                draft?.appliedTranscript = original.transcript
                applied = true
                changed()
                try await flush()
                if rows.isEmpty { error = "В тексте не нашлось еды. Уточните диктовку или добавьте строку вручную." }
            } catch is CancellationError {
                log("parseCancelled", fields: ["draftID": original.id.uuidString, "dictationID": original.dictationID?.uuidString ?? ""])
            } catch {
                log("parseFailed", fields: ["draftID": original.id.uuidString, "dictationID": original.dictationID?.uuidString ?? "", "error": error.localizedDescription])
                if !Task.isCancelled, draft?.id == original.id, applied || owns(original) { self.error = error.localizedDescription }
            }
        }
    }
    func owns(_ value: MealDraft) -> Bool { !Task.isCancelled && draft?.id == value.id && draft?.revision == value.revision && draft?.operationID == value.operationID }
    /// Cancel only the owned audio clip; previously added meal rows are untouched.
    @discardableResult func discardRecording(draftID: UUID, file: String) -> Bool {
        guard !busy, !saving, draft?.id == draftID, draft?.audioFile == file else { return false }
        liveProgress = nil
        let cancelled = draft!
        if cancelled.liveMode == true, let dictationID = cancelled.dictationID {
            let removed = cancelled.rows.filter { $0.dictationID == dictationID }
            log("liveCancelledRows", fields: ["snapshot": json(removed)])
            draft?.rows.removeAll { $0.dictationID == dictationID }
            for row in removed { candidates[row.id] = nil }
        }
        draft?.livePendingText = nil
        draft?.liveAudioSampleOffset = nil
        draft?.liveSemanticRows = nil
        draft?.audioFile = nil; draft?.transcript = ""; draft?.appliedTranscript = nil
        draft?.dictationPreviewOnly = nil; draft?.pendingResponse = nil
        draft?.lastRequestSeconds = nil; draft?.inputTokens = nil; draft?.outputTokens = nil
        log("recordingCancelled")
        changed()
        pendingAudioArchive = (file, cancelled)
        audioArchiving = Task { try await preserveAudio(file, owner: cancelled) }
        Task {
            do { try await flush(); if try await !repository.audioIsReferenced(file) { VoiceFiles.remove(file) } }
            catch { if draft?.id == draftID { self.error = "Запись остановлена, но отмена пока не сохранена. " + error.localizedDescription } }
        }
        return true
    }
    @discardableResult func cancel() -> Task<Void, Never>? {
        let previous = operation
        previous?.cancel(); operation = nil; busy = false
        draft?.operationID = nil; persistLater()
        return previous
    }
    func close() async {
        guard !saving else { return }
        cancel()
        do { try await flush(); showing = false }
        catch { self.error = "Не удалось сохранить черновик. " + error.localizedDescription }
    }
    /// The system sheet has already gone away. Keep the same draft, including empty ones.
    func dismissed() async {
        guard !showing, draft != nil else { return }
        cancel()
        do { try await flush() }
        catch { self.error = "Черновик пока не сохранён на диск. " + error.localizedDescription }
    }
    func commit() async {
        guard !saving, !busy, var value = draft else { return }
        guard !hasPendingDictation else {
            error = "Диктовка ещё не обработана. Продолжите её или удалите черновик."; return
        }
        saving = true
        defer { saving = false }
        do {
            let confirmedAt = Date()
            if value.editingEntryID == nil, value.timing?.mode == .now,
               let startedAt = value.timing?.startedAt,
               value.day == Day(startedAt) {
                value.day = Day(confirmedAt)
            }
            try await flush()
            log("commitRequested", fields: ["snapshot": json(value), "validatedRows": json(try value.rows.map { try $0.validated() })])
            try await flushLog()
            try await repository.commit(value, now: confirmedAt)
            writer.forget(value.id)
            for row in value.rows { log("confirmed", row: row, fields: ["product": row.product?.id ?? "", "food": row.food, "amount": row.quantity, "attention": row.matchAttention ?? ""]) }
            log("commitSucceeded", fields: ["snapshot": json(try value.rows.map { try $0.validated() }), "day": value.day.rawValue, "meal": value.meal.rawValue])
            await logTask?.value
            drafts.removeAll { $0.id == value.id }; draft = nil; showing = false; candidates = [:]
            if let file = value.audioFile, try await !repository.audioIsReferenced(file) { VoiceFiles.remove(file) }
            store.select(value.day); await store.reloadAsync(); store.savedCount += 1
        } catch { self.error = error.localizedDescription }
    }
    func consumePlanned(_ episodeID: UUID) async {
        guard !saving else { return }
        // An open draft owns its rows; don't overwrite its source from another screen.
        guard draft?.timing?.episodeID != episodeID else {
            error = "Сначала сохраните открытый черновик этого приёма."; return
        }
        saving = true; defer { saving = false }
        do {
            log("consumePlanRequested", fields: ["episodeID": episodeID.uuidString])
            try await flushLog()
            try await repository.consumeEpisode(episodeID)
            await store.reloadAsync(); store.savedCount += 1
            log("consumePlanSucceeded", fields: ["episodeID": episodeID.uuidString])
        } catch { self.error = error.localizedDescription }
    }
    func reassignMeal(_ entries: [DiaryItem], to destination: Meal) async {
        guard !saving, !entries.isEmpty else { return }
        let ids = entries.map(\.id)
        guard draft?.editingEntryID.map({ !ids.contains($0) }) ?? true else {
            error = "Сначала сохраните или удалите открытый черновик этого приёма."; return
        }
        saving = true; defer { saving = false }
        do {
            log("mealReassignRequested", fields: ["entryIDs": ids.map(\.uuidString).joined(separator: ","),
                "destination": destination.rawValue])
            try await flushLog()
            try await repository.reassignMeal(ids, to: destination)
            await store.reloadAsync(); store.savedCount += 1
            log("mealReassignSucceeded", fields: ["entryIDs": ids.map(\.uuidString).joined(separator: ","),
                "destination": destination.rawValue])
        } catch { self.error = error.localizedDescription }
    }
    func discard() async {
        guard !saving else { return }
        cancel(); saving = true
        defer { saving = false }
        do {
            try await writer.flush()
            log("draftDiscarded", fields: ["snapshot": json(draft)])
            if let owner = draft, let file = owner.audioFile { try await preserveAudio(file, owner: owner) }
            try await flushLog()
            guard let value = draft else { return }
            try await repository.discardDraft(value.id)
            writer.forget(value.id)
            drafts.removeAll { $0.id == value.id }
            if let file = value.audioFile, try await !repository.audioIsReferenced(file) { VoiceFiles.remove(file) }
            draft = nil; showing = false; candidates = [:]
        } catch { self.error = error.localizedDescription }
    }
    func removeEntry() async {
        guard !saving, let id = draft?.editingEntryID else { return }
        saving = true
        defer { saving = false }
        do {
            try await writer.flush()
            log("entryDeleteRequested", fields: ["snapshot": json(draft), "entryID": id.uuidString])
            try await flushLog()
            try await repository.remove(id)
            log("entryDeleted", fields: ["entryID": id.uuidString]); await logTask?.value
            if let value = draft {
                try await repository.discardDraft(value.id)
                drafts.removeAll { $0.id == value.id }
                if let file = value.audioFile, try await !repository.audioIsReferenced(file) { VoiceFiles.remove(file) }
            }
            draft = nil; showing = false
            await store.reloadAsync(); store.savedCount += 1
        } catch { self.error = error.localizedDescription }
    }
    func resumeProductLink(_ library: ProductLibrary) async {
        guard !saving, let owner = draft, let rowID = owner.linkingRowID, let productID = owner.linkingProductID else { return }
        do {
            // Product editor commits separately. A restart between the two saves can finish the link here.
            if let product = try await store.productRepository.product(id: productID) {
                guard !saving, owns(owner) else { return }
                choose(product, for: rowID)
                draft?.linkingRowID = nil; draft?.linkingProductID = nil; draft?.linkingProductDraftID = nil; changed(); try await flush()
            }
        } catch { if owns(owner) { self.error = error.localizedDescription } }
    }
    func createProduct(for row: MealRow, library: ProductLibrary) async {
        guard let owner = draft, owner.rows.contains(where: { $0.id == row.id }) else { return }
        log("createOrEditCard", row: row, fields: ["food": row.food])
        await library.load()
        guard owns(owner) else { return }
        if owner.linkingRowID == row.id, let id = owner.linkingProductDraftID,
           library.drafts.contains(where: { $0.id == id }) { await library.resume(id) }
        else { await library.begin(row.product) }
        guard owns(owner) else { return }
        if row.product == nil { library.draft?.name = row.food; library.changed() }
        guard let productDraft = library.draft else { return }
        draft?.linkingRowID = row.id
        draft?.linkingProductID = productDraft.editingProductID ?? productDraft.productID ?? productDraft.id.uuidString
        draft?.linkingProductDraftID = productDraft.id
        changed()
        do { try await flush() } catch { self.error = error.localizedDescription }
    }
}
