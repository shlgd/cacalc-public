import Foundation

enum FoodUnit: String, Codable, CaseIterable, Sendable {
    case g, kg, ml, l, pc, portion
    var title: String {
        switch self { case .g: "г"; case .kg: "кг"; case .ml: "мл"; case .l: "л"; case .pc: "шт"; case .portion: "порц." }
    }
    var basis: Basis? {
        switch self { case .g, .kg: .g; case .ml, .l: .ml; case .pc, .portion: nil }
    }
    var multiplier: Decimal { self == .kg || self == .l ? 1000 : 1 }
}

/// Each nutrient can be unknown independently. These are values for the eaten portion.
struct PortionSnapshot: Codable, Equatable, Sendable {
    var calories: Decimal?
    var protein: Decimal?
    var fat: Decimal?
    var carbs: Decimal?
    static let unknown = Self()
    init(calories: Decimal? = nil, protein: Decimal? = nil, fat: Decimal? = nil, carbs: Decimal? = nil) {
        self.calories = calories; self.protein = protein; self.fat = fat; self.carbs = carbs
    }
    init(product: Product?, amount: Decimal?, unit: FoodUnit?) {
        self = .unknown
        guard let product, let amount, let unit, amount > 0, unit.basis == product.basis else { return }
        let factor = amount * unit.multiplier / 100
        calories = product.calories.map { $0 * factor }; protein = product.protein.map { $0 * factor }
        fat = product.fat.map { $0 * factor }; carbs = product.carbs.map { $0 * factor }
    }
    var complete: Bool { calories != nil && protein != nil && fat != nil && carbs != nil }
    /// A subtotal of known values, never a claim of complete nutrition.
    var known: Nutrition { Nutrition(calories: calories ?? 0, protein: protein ?? 0, fat: fat ?? 0, carbs: carbs ?? 0) }
}

struct NutritionSummary: Sendable {
    var count = 0
    var known = Nutrition.zero
    var missingCalories = 0
    var missingProtein = 0
    var missingFat = 0
    var missingCarbs = 0
    init(_ snapshots: [PortionSnapshot]) {
        count = snapshots.count
        for value in snapshots {
            known = known + value.known
            if value.calories == nil { missingCalories += 1 }
            if value.protein == nil { missingProtein += 1 }
            if value.fat == nil { missingFat += 1 }
            if value.carbs == nil { missingCarbs += 1 }
        }
    }
}

/// A preview is computed from snapshots in memory; editing replaces the old portion.
struct MealNutritionPreview: Sendable {
    let before: NutritionSummary
    let added: NutritionSummary
    let after: NutritionSummary
    let goals: Nutrition?
    init(page: DiaryPageData, draft: MealDraft) {
        let existing = page.items.filter { $0.day == draft.day && $0.id != draft.editingEntryID && $0.row.timing?.isPlanned != true }.map { $0.row.portion }
        let incoming = draft.rows.map(\.portion)
        before = NutritionSummary(existing)
        added = NutritionSummary(incoming)
        after = NutritionSummary(existing + incoming)
        goals = page.goals
    }
    func nutrient(_ value: KeyPath<Nutrition, Decimal>, missing: KeyPath<NutritionSummary, Int>) -> MealNutrientPreview {
        MealNutrientPreview(before: before.known[keyPath: value], added: added.known[keyPath: value],
            total: after.known[keyPath: value], target: goals?[keyPath: value],
            addedMissing: added[keyPath: missing], totalMissing: after[keyPath: missing],
            addedCount: added.count, totalCount: after.count)
    }
}

struct MealNutrientPreview {
    let before: Decimal
    let added: Decimal
    let total: Decimal
    let target: Decimal?
    let addedMissing: Int
    let totalMissing: Int
    let addedCount: Int
    let totalCount: Int
    var beforeProgress: Double { Budget(eaten: before, target: target).progress }
    var progress: Double { Budget(eaten: total, target: target).progress }
    var exceeded: Bool { target.map { total > $0 } ?? false }
    var remaining: Decimal? { totalMissing == 0 ? target.map { abs($0 - total) } : nil }
    var totalText: String {
        if totalMissing > 0 && totalMissing == totalCount { return "—" }
        return (totalMissing > 0 ? "≥ " : "") + Numbers.display(total, places: 0)
    }
    var addedText: String {
        if addedCount == 0 { return "" }
        if addedMissing > 0 && addedMissing == addedCount { return "—" }
        return (addedMissing > 0 ? "≥ +" : "+") + Numbers.display(added, places: 0)
    }
}

struct MealRow: Codable, Equatable, Identifiable, Sendable {
    var timing: MealTiming?
    var addedAt: Date?
    var id = UUID()
    var readError: String?
    var food: String
    var quantity = ""
    var unit: FoodUnit?
    var product: Product?
    var suggested = false
    var matchingPending: Bool?
    // Revision of the identity being matched, independent of manual weight edits.
    var matchingRevision: UUID?
    var matchingOperationID: UUID?
    var dictationID: UUID?
    var matchTraceID: String?
    var matchAttention: String?
    var matchContextIDs: [String]?
    var matchOptions: [ProductCandidate]?
    var batchPortions: Decimal?
    // Original spoken serving count; nil after a manual quantity edit.
    var requestedPreparedPortions: Decimal?
    var manualNutrition: PortionSnapshot?
    var requiresAttention: Bool { if let manualNutrition { return !manualNutrition.complete }; return matchAttention != nil || product == nil || amount == nil || unit == nil || product?.nutrition == nil || product?.basis == .unknown }
    var confirmedBasis: Bool?
    // Set only at confirmation. Subsequent catalog edits never recalculate this value.
    var snapshot: PortionSnapshot?
    var amount: Decimal? { try? Numbers.parse(quantity, positive: true) }
    var displayName: String { product?.name ?? food }
    /// Format automatic portion estimates for editing without changing the stored Decimal.
    /// A real edit clears requestedPreparedPortions, so manually typed text stays untouched.
    var quantityEditingText: String {
        guard requestedPreparedPortions != nil, unit == .g, let amount else { return quantity }
        return Numbers.display(amount, grouping: false)
    }
    var quantityLabel: String {
        guard let amount else { return manualNutrition == nil ? "Количество не указано" : "Быстрый ввод" }
        return "\(Numbers.display(amount)) \(unit?.title ?? "· единица не указана")"
    }
    var portion: PortionSnapshot { manualNutrition ?? snapshot ?? PortionSnapshot(product: product, amount: amount, unit: unit) }
    func validated() throws -> Self {
        if let readError { throw FoodError.database(readError) }
        var result = self
        result.food = food.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.food.isEmpty, result.food.count <= 300 else { throw FoodError.database("Укажите название еды, до 300 символов.") }
        if !quantity.trimmingCharacters(in: .whitespaces).isEmpty { _ = try Numbers.parse(quantity, positive: true) }
        if let manualNutrition {
            guard product == nil, manualNutrition.complete,
                  [manualNutrition.calories, manualNutrition.protein, manualNutrition.fat, manualNutrition.carbs]
                    .allSatisfy({ $0.map { !$0.isNaN && $0 >= 0 && $0 <= 1_000_000 } ?? false })
            else { throw FoodError.missingNutrition }
        }
        result.snapshot = portion
        result.suggested = false
        // Candidate snapshots belong to the draft and bounded diagnostics, not permanent diary storage.
        result.matchOptions = nil; result.matchContextIDs = nil
        return result
    }
}

struct MealArchiveEvent: Codable, Equatable, Sendable {
    var name: String
    var fields: [String: String]
}

struct MealDraft: Codable, Equatable, Identifiable, Sendable {
    var timing: MealTiming?
    var id = UUID()
    var revision = UUID()
    var operationID: UUID?
    var linkingProductDraftID: UUID?
    var legacyInput: FoodDraft?
    var day: Day
    var meal: Meal
    var rows: [MealRow] = []
    var transcript = ""
    var auditPending: [MealArchiveEvent]?
    var appliedTranscript: String?
    var dictationPreviewOnly: Bool?
    var audioFile: String?
    var dictationID: UUID?
    var liveMode: Bool?
    var liveRevision: UUID?
    var liveOperationID: UUID?
    var liveAudioSampleOffset: Int?
    var livePendingText: String?
    var livePendingIsProvisional: Bool?
    // Last ASR proposal for the current uncommitted audio window; IDs survive
    // restart so final transcription updates the same rows instead of duplicating.
    var liveSemanticRows: [MealRow]?
    var editingEntryID: UUID?
    // Raw response is retained before validation; never silently lost on a parse/save failure.
    var pendingResponse: String?
    var lastRequestSeconds: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var linkingRowID: UUID?
    var linkingProductID: String?
}

struct MatchHistory: Sendable {
    var phrase: String
    var product: Product
    var count: Int
    var lastUsed: Date
}

struct ProductCandidate: Codable, Equatable, Identifiable, Sendable {
    var product: Product
    var score: Double
    var reason: String
    var automaticEligible: Bool = false
    var evidence: SearchEvidence?
    var id: String { product.id }
}

/// Deterministic filtering AFTER ASR. Raw transcripts never pass through this destructively.
enum FoodWordFilter {
    struct Removed: Codable, Equatable {
        let word: String
        let position: Int
        let reason: String
    }
    struct Result {
        let text: String
        let removed: [Removed]
    }
    private static let conversation = Set("""
        ну вот так короче пожалуйста блин блять блядь сука нахуй ебать
        э эм эээ мм ага угу да давай давайте
        я мы мне нам это типа сейчас уже просто получается
        добавил добавила добавили добавляю добавим добавить
        съел съела съели ем скушал скушала записываю записать
        купил купила купили вчера потом затем теперь также еще
        который которую которое которые которого тот та то те
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let connectors: Set<String> = ["и", "но", "что", "как", "бы"]
    private static let prepositions: Set<String> = ["от", "из", "на", "с", "со", "в", "во"]
    private static let units: Set<String> = ["г", "гр", "грамм", "грамма", "граммов"]
    static func apply(_ text: String, search: Bool = false) -> Result {
        let words = text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        var kept: [String] = [], removed: [Removed] = []
        for (position, word) in words.enumerated() {
            let reason: String?
            if conversation.contains(word) { reason = "conversation" }
            else if connectors.contains(word) { reason = "connector" }
            else if units.contains(word) { reason = "massUnit" }
            else if search && prepositions.contains(word) { reason = "searchPreposition" }
            else if !word.contains(where: { $0.isLetter || $0.isNumber }) { reason = "punctuation" }
            else { reason = nil }
            if let reason { removed.append(Removed(word: word, position: position, reason: reason)) }
            else { kept.append(word) }
        }
        return Result(text: kept.joined(separator: " "), removed: removed)
    }
}

enum MealMatcher {
    private static let tokenizer = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:[.,]\d+)?(?:\s*%)?"#)
    private static let bananaForms = try! NSRegularExpression(pattern: #"^банан(а|у|ом|е|ы|ов|ам|ами|ах)?$"#)
    static func normalize(_ value: String) -> String {
        let text = value.lowercased(with: Locale(identifier: "ru_RU")).replacingOccurrences(of: "ё", with: "е")
        return tokenizer.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "") }
        }.joined(separator: " ")
    }
    static func words(_ value: String) -> Set<String> {
        Set(normalize(value).split(separator: " ").map { token in
            let text = String(token)
            // Snowball treats the final н of «банан» as a verb suffix. Keep this noun family together.
            if bananaForms.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return "банан" }
            if text == "яиц" { return "яйц" }
            return RussianSearchStem.stem(text)
        })
    }
    static func searchPhrase(_ value: String) -> String {
        FoodWordFilter.apply(normalize(value), search: true).text
    }
    static func searchWords(_ value: String) -> Set<String> {
        words(searchPhrase(value)).filter { $0.count >= 2 && $0.allSatisfy(\.isLetter) }
    }
    static func rank(_ phrase: String, products: [Product], history: [MatchHistory], now: Date = Date()) -> [ProductCandidate] {
        SearchIndex(products: products).rank(phrase, history: history, now: now)
    }
    static func suggestion(_ ranked: [ProductCandidate]) -> Product? {
        guard selectionReason(ranked) == "selected" else { return nil }
        return ranked.first?.product
    }

    static func selectionReason(_ ranked: [ProductCandidate]) -> String {
        guard let first = ranked.first else { return "no-candidates" }
        guard first.automaticEligible else { return first.evidence?.selectionRule ?? "ineligible" }
        guard first.score >= 78 else { return "below-score-threshold" }
        guard ranked.count == 1 || first.score - ranked[1].score >= 16 else { return "close-alternative" }
        return "selected"
    }

}

extension Meal {
    static let currentCases: [Meal] = [.breakfast, .lunch, .dinner]
}

/// Russian Snowball rules (snowballstem.org/algorithms/russian/stemmer.html).
/// Search representation only: the displayed and saved source names are untouched.
enum RussianSearchStem {
    private static let vowels = Set("аеиоуыэюя")
    private static let endings: [String: [String]] = {
        let groups = [
        "ившись ывшись ивши ывши ив ыв",
        "вшись вши в",
        "ся сь",
        "ее ие ые ое ими ыми ей ий ый ой ем им ым ом его ого ему ому их ых ую юю ая яя ою ею",
        "ивш ывш ующ",
        "ем нн вш ющ щ",
        "ила ыла ена ейте уйте ите или ыли ей уй ил ыл им ым ен ило ыло ено ят ует уют ит ыт ены ить ыть ишь ую ю",
        "ла на ете йте ли й л ем н ло но ет ют ны ть ешь нно",
        "а ев ов ие ье е иями ями ами еи ии и ией ей ой ий й иям ям ием ем ам ом о у ах иях ях ы ь ию ью ю ия ья я",
        "и",
        "ь",
        "ейше ейш",
        "ость",
        "ост"
        ]
        return Dictionary(uniqueKeysWithValues: groups.map { ($0, $0.split(separator: " ").map(String.init).sorted { $0.count > $1.count }) })
    }()
    static func stem(_ input: String) -> String {
        let word = input.replacingOccurrences(of: "ё", with: "е")
        let letters = Array(word)
        guard let vowel = letters.firstIndex(where: { vowels.contains($0) }) else { return word }
        let rv = vowel + 1
        func region(_ start: Int) -> Int {
            guard start + 1 < letters.count else { return letters.count }
            for i in (start + 1)..<letters.count where vowels.contains(letters[i - 1]) && !vowels.contains(letters[i]) { return i + 1 }
            return letters.count
        }
        let r2 = region(region(0))
        var tail = String(letters.dropFirst(rv))
        @discardableResult func strip(_ alternatives: String, after: Set<Character>? = nil) -> Bool {
            for suffix in (Self.endings[alternatives] ?? [alternatives]) where tail.hasSuffix(suffix) {
                let rest = String(tail.dropLast(suffix.count))
                if let after, rest.last.map({ after.contains($0) }) != true { continue }
                tail = rest; return true
            }
            return false
        }
        let aya = Set("ая")
        if !strip("ившись ывшись ивши ывши ив ыв") && !strip("вшись вши в", after: aya) {
            strip("ся сь")
            if strip("ее ие ые ое ими ыми ей ий ый ой ем им ым ом его ого ему ому их ых ую юю ая яя ою ею") {
                if !strip("ивш ывш ующ") { strip("ем нн вш ющ щ", after: aya) }
            } else if !strip("ила ыла ена ейте уйте ите или ыли ей уй ил ыл им ым ен ило ыло ено ят ует уют ит ыт ены ить ыть ишь ую ю") && !strip("ла на ете йте ли й л ем н ло но ет ют ны ть ешь нно", after: aya) {
                strip("а ев ов ие ье е иями ями ами еи ии и ией ей ой ий й иям ям ием ем ам ом о у ах иях ях ы ь ию ью ю ия ья я")
            }
        }
        strip("и")
        for suffix in ["ость", "ост"] where tail.hasSuffix(suffix) && rv + tail.count - suffix.count >= r2 { strip(suffix); break }
        if !strip("ь") { strip("ейше ейш"); if tail.hasSuffix("нн") { tail.removeLast() } }
        return String(letters.prefix(rv)) + tail
    }
}


/// Small explicit list of observed standalone ASR noise phrases, not a language blacklist.
enum MealSpeechPhraseFilter {
    static func rejectedPhrase(_ text: String) -> String? {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let normalized = words.joined(separator: " ")
        switch normalized {
        case "yeah", "thank you", "i m not sure", "im not sure": return normalized
        default: return nil
        }
    }
}


/// Payload v2: optional on old JSON. Legacy rows remain consumed with unknown time.
struct MealTiming: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable { case now, earlier, planned }
    var version = 2
    var episodeID = UUID()
    var mode: Mode = .now
    var startedAt = Date()
    var selectedAt: Date?
    var consumedAt: Date?
    var savedAt: Date?
    var updatedAt: Date?
    var source = "unknown"
    var timeZoneID = TimeZone.autoupdatingCurrent.identifier
    var isPlanned: Bool { mode == .planned }
    func confirmed(rows: [MealRow], day: Day, now: Date) -> Self {
        var result = self
        result.updatedAt = now
        if result.savedAt == nil { result.savedAt = now }
        if mode == .planned { result.consumedAt = nil; result.source = "planned" }
        else if mode == .earlier, let selectedAt {
            result.consumedAt = selectedAt; result.source = "user"
        } else if mode == .now, result.consumedAt == nil, Day(now) == day {
            result.consumedAt = now; result.source = "save-confirmation"
        }
        return result
    }
}

/// Rows saved together share an episodeID and must remain one visible meal card.
/// Legacy rows have no episode identity, so they stay together rather than being split by guesswork.
struct DiaryEpisode: Identifiable, Equatable, Sendable {
    var id: String
    var entries: [DiaryItem]
    var time: Date?

    static func snacks(in items: [DiaryItem]) -> [Self] {
        let groups = Dictionary(grouping: items.filter { $0.meal == .snack }) { item in
            item.row.timing.map { "episode:" + $0.episodeID.uuidString } ?? "legacy"
        }
        return groups.map { id, entries in
            let sorted = entries.sorted { (eventTime($0) ?? .distantPast) < (eventTime($1) ?? .distantPast) }
            return Self(id: id, entries: sorted, time: sorted.compactMap(eventTime).min())
        }.sorted {
            if $0.time != $1.time { return ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
            return $0.id < $1.id
        }
    }

    private static func eventTime(_ item: DiaryItem) -> Date? {
        item.row.timing?.consumedAt ?? item.row.timing?.selectedAt ?? item.row.timing?.startedAt ?? item.row.addedAt
    }
}

struct AdaptiveMealPlan: Sendable {
    static let ruleVersion = "adaptive-v4"
    struct Suggestion: Identifiable, Codable, Sendable {
        var meal: Meal
        var start: Date
        var end: Date
        var nutrition: PortionSnapshot
        var id: Meal { meal }
    }
    var suggestions: [Suggestion]
    var forecast: NutritionSummary
    var explanation: String
    var remaining: PortionSnapshot
    static func calculate(page: DiaryPageData, day: Day, now: Date = Date(), intervalHours: Double = 4, bedtimeHour: Int = 23, history: [DiaryItem] = [], wakeTime: Date? = nil) -> Self {
        let consumed = page.items.filter { $0.row.timing?.isPlanned != true }
        let planned = page.items.filter { $0.row.timing?.isPlanned == true }
        let used = NutritionSummary(page.items.map { $0.row.portion })
        func remainder(_ key: KeyPath<Nutrition, Decimal>, _ missing: Int) -> Decimal? {
            guard missing == 0, let goal = page.goals else { return nil }
            return goal[keyPath: key] - used.known[keyPath: key]
        }
        let remaining = PortionSnapshot(calories: remainder(\.calories, used.missingCalories), protein: remainder(\.protein, used.missingProtein), fat: remainder(\.fat, used.missingFat), carbs: remainder(\.carbs, used.missingCarbs))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .autoupdatingCurrent
        func clock(_ hour: Int) -> Date { cal.date(bySettingHour: hour, minute: 0, second: 0, of: day.date)! }
        let bedtime = clock(max(18, min(23, bedtimeHour)))
        let interval = max(2, min(6, intervalHours)) * 3600
        let unavailable = Set(page.items.map(\.meal))
        let rhythm = MealRhythm.learn(history, before: min(day, Day(now)))
        let templates: [(Meal, Int, Decimal)] = [(.breakfast, 9, 600), (.lunch, 14, 760), (.dinner, 20, 740)]
        let dayStart = cal.startOfDay(for: day.date)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        // Anchors belong to their main meal. A later lunch must not move breakfast,
        // and neither a consumed nor a planned snack resets the main-meal interval.
        let anchors = Dictionary(uniqueKeysWithValues: templates.compactMap { meal, _, _ -> (Meal, Date)? in
            // The start of a main meal is stable when more food is appended later.
            let fact = consumed.filter { $0.meal == meal }.compactMap { $0.row.timing?.consumedAt }.filter { Day($0) == day }.min()
            let plan = planned.filter { $0.meal == meal }.compactMap { $0.row.timing?.selectedAt }.filter { Day($0) == day }.min()
            return (fact ?? plan).map { (meal, $0) }
        })
        var centers: [Date] = []
        var limits: [Date] = []
        var followsAnchor = false
        var shifted = false
        for (index, template) in templates.enumerated() {
            let (meal, hour, _) = template
            let previous = centers.last
            if let fixed = anchors[meal] {
                // Retain actual records as entered, even when their labels/times disagree.
                // Only the following predictions use the latest preceding main-meal time.
                centers.append(max(previous ?? fixed, fixed)); limits.append(dayEnd)
                followsAnchor = true
                continue
            }
            let learned = rhythm[meal]
            var nominal = learned.map { cal.date(bySettingHour: Int($0.centerMinutes) / 60, minute: Int($0.centerMinutes) % 60, second: 0, of: day.date)! } ?? clock(hour)
            if meal == .breakfast, let wakeTime, Day(wakeTime) == day {
                nominal = wakeTime.addingTimeInterval(90 * 60)
                followsAnchor = true
            }
            let nextFixed = templates.indices.dropFirst(index + 1).first { candidate in
                anchors[templates[candidate].0].map { $0 > (previous ?? dayStart) } ?? false
            }
            let count = (nextFixed ?? templates.count) - index
            let comfortEnd = bedtime.addingTimeInterval(-3600)
            let limit: Date
            if let nextFixed, let fixed = anchors[templates[nextFixed].0] {
                // Fixed main meals constrain only their predecessors, not every meal.
                let gap = fixed.timeIntervalSince(previous ?? dayStart)
                limit = fixed.addingTimeInterval(-min(1800, gap / 4))
            } else {
                // A real late meal outranks the soft bedtime preference.
                limit = (previous ?? dayStart) >= comfortEnd ? dayEnd : comfortEnd
            }
            let base = previous ?? dayStart
            let room = max(0, limit.timeIntervalSince(base))
            // Trim flexible widths before shortening the preferred interval. Historical
            // uncertainty must not push the centre away from today's factual anchor.
            let latestCenter = limit.addingTimeInterval(-min(1800, room / Double(count + 1)))
            let step = min(interval, max(0, latestCenter.timeIntervalSince(base)) / Double(count))
            let latest = latestCenter.addingTimeInterval(-step * Double(count - 1))
            let preferred = followsAnchor && previous != nil
                ? base.addingTimeInterval(step)
                : max(nominal, previous.map { $0.addingTimeInterval(step) } ?? nominal)
            let center = min(preferred, latest)
            centers.append(center); limits.append(limit)
            shifted = shifted || center != clock(hour)
        }
        var windows: [(Meal, Date, Date, Decimal)] = []
        for (index, template) in templates.enumerated() where day >= Day(now) && !unavailable.contains(template.0) {
            let (meal, _, weight) = template
            let center = centers[index]
            let halfWidth = (rhythm[meal]?.halfWindowMinutes ?? 60) * 60
            var start = center.addingTimeInterval(-halfWidth)
            var end = min(center.addingTimeInterval(halfWidth), limits[index])
            // Neighbour midpoints keep widened/compressed windows in meal order.
            if index > 0 { start = max(start, centers[index - 1].addingTimeInterval(center.timeIntervalSince(centers[index - 1]) / 2)) }
            if index + 1 < centers.count { end = min(end, center.addingTimeInterval(centers[index + 1].timeIntervalSince(center) / 2)) }
            // Windows stay anchored while the clock advances; an unrecorded meal
            // remains visible after its window instead of moving the whole day.
            windows.append((meal, start, end, weight))
        }
        let weights = windows.reduce(Decimal.zero) { $0 + $1.3 }
        var comfortLimited = false
        let suggestions = windows.map { meal, start, end, weight -> Suggestion in
            let share = weight / max(1, weights)
            // Soft portion ceiling, not a nutrition requirement: leave residual visible.
            let energy = remaining.calories.map { max(0, $0) * share }
            let cap = (page.goals?.calories ?? 0) * Decimal(string: "0.4")!
            let factor: Decimal = energy.map { $0 > cap && $0 > 0 ? cap / $0 : 1 } ?? 1
            if factor < 1 { comfortLimited = true }
            func value(_ x: Decimal?) -> Decimal? { x.map { max(0, $0) * share * factor } }
            return Suggestion(meal: meal, start: start, end: end, nutrition: PortionSnapshot(calories: value(remaining.calories), protein: value(remaining.protein), fat: value(remaining.fat), carbs: value(remaining.carbs)))
        }
        let explanation: String
        if page.goals == nil { explanation = "Задайте цели, чтобы видеть ориентиры количества еды." }
        else if used.missingCalories > 0 { explanation = "У части еды неизвестны калории. Точный остаток пока не рассчитан." }
        else if (remaining.calories ?? 0) < 0 { explanation = "Прогноз выше цели. Следующий приём можно выбрать по голоду и удобству." }
        else if comfortLimited || (suggestions.isEmpty && (remaining.calories ?? 0) > 0) { explanation = "Не весь остаток помещается в удобный план. Добирать его через силу не нужно." }
        else if shifted { explanation = "Окна обновлены с учётом времени еды. Их можно менять под свои планы." }
        else { explanation = "Ориентиры можно менять. Дополнительная еда тоже учитывается в дне." }
        return Self(suggestions: suggestions, forecast: NutritionSummary(page.items.map { $0.row.portion } + suggestions.map(\.nutrition)), explanation: explanation, remaining: remaining)
    }
}

/// Local observed schedule, not an inferred waking time or nutritional optimum.
enum MealRhythm {
    struct Window: Sendable {
        var centerMinutes: Double
        var halfWindowMinutes: Double
        var days: Int
    }
    static func learn(_ history: [DiaryItem], before day: Day) -> [Meal: Window] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .autoupdatingCurrent
        let valid = history.filter {
            $0.day < day && $0.day >= day.offset(-28) && $0.meal != .snack &&
            $0.row.timing?.isPlanned == false && $0.row.timing?.consumedAt != nil
        }
        var result: [Meal: Window] = [:]
        for meal in Meal.currentCases {
            // One observation per day: many ingredient rows must not outweigh another day.
            let grouped = Dictionary(grouping: valid.filter { $0.meal == meal }, by: \.day)
            let minutes = grouped.values.compactMap { items -> Double? in
                guard let date = items.compactMap({ $0.row.timing?.consumedAt }).min(),
                      let item = items.first, Day(date) == item.day else { return nil }
                return Double(calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date))
            }.sorted()
            guard minutes.count >= 3 else { continue }
            func quantile(_ q: Double) -> Double {
                let p = Double(minutes.count - 1) * q
                let lo = Int(p), hi = min(lo + 1, minutes.count - 1)
                return minutes[lo] + (minutes[hi] - minutes[lo]) * (p - Double(lo))
            }
            result[meal] = Window(centerMinutes: quantile(0.5),
                halfWindowMinutes: min(90, max(60, (quantile(0.8) - quantile(0.2)) / 2 + 30)), days: minutes.count)
        }
        return result
    }
}

/// Merge overlapping stage/source records before choosing a substantial sleep episode.
enum SleepWindow {
    static func wake(from intervals: [DateInterval], now: Date) -> Date? {
        HealthInsights.nights(intervals.filter { $0.start >= now.addingTimeInterval(-48 * 3600) }, now: now)
            .filter { Day($0.end) == Day(now) }.max { $0.seconds < $1.seconds }?.end
    }
}

struct WakeEstimate: Sendable {
    var date: Date
    var observed: Bool
    var days: Int
    var earliest: Date
    var latest: Date
    static func calculate(intervals: [DateInterval], now: Date) -> Self? {
        if let actual = SleepWindow.wake(from: intervals, now: now) {
            return Self(date: actual, observed: true, days: 1, earliest: actual, latest: actual)
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .autoupdatingCurrent
        let today = Day(now)
        var minutes: [Double] = []
        for offset in 1...28 {
            let day = today.offset(-offset)
            let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: day.date)!
            if let wake = SleepWindow.wake(from: intervals, now: end) {
                minutes.append(Double(calendar.component(.hour, from: wake) * 60 + calendar.component(.minute, from: wake)))
            }
        }
        guard minutes.count >= 3 else { return nil }
        minutes.sort()
        func percentile(_ fraction: Double) -> Double {
            let index = Double(minutes.count - 1) * fraction
            let lo = Int(index), hi = min(lo + 1, minutes.count - 1)
            return minutes[lo] + (minutes[hi] - minutes[lo]) * (index - Double(lo))
        }
        func clock(_ minutes: Double) -> Date {
            calendar.date(bySettingHour: Int(minutes) / 60, minute: Int(minutes) % 60, second: 0, of: today.date)!
        }
        return Self(date: clock(percentile(0.5)), observed: false, days: minutes.count,
            earliest: clock(percentile(0.2)), latest: clock(percentile(0.8)))
    }
}

/// Start with breakfast, then follow the consumed main meals in order.
/// Later main meals use their window with 30 minutes before / 90 minutes after;
/// food between them defaults to a snack. Manual selection remains available.
enum MealEntrySuggestion {
    static let ruleVersion = "entry-sequence-v1"
    static func choose(windows: [AdaptiveMealPlan.Suggestion], eaten: Set<Meal>, at date: Date) -> Meal {
        // A historical clock or a planned meal does not mean today's breakfast was eaten.
        guard let last = Meal.currentCases.lastIndex(where: { eaten.contains($0) }) else { return .breakfast }
        let next = last + 1
        guard next < Meal.currentCases.count else { return .snack }
        let meal = Meal.currentCases[next]
        return windows.contains {
            $0.meal == meal && date >= $0.start.addingTimeInterval(-1800) && date <= $0.end.addingTimeInterval(5400)
        } ? meal : .snack
    }
    static func choose(page: DiaryPageData, day: Day, now: Date, intervalHours: Double, bedtimeHour: Int, history: [DiaryItem], wakeTime: Date?) -> Meal {
        let calendar = Calendar.autoupdatingCurrent
        let reference = calendar.startOfDay(for: day.date)
        let plan = AdaptiveMealPlan.calculate(page: page, day: day, now: reference, intervalHours: intervalHours, bedtimeHour: bedtimeHour, history: history, wakeTime: wakeTime)
        let eaten = Set(page.items.filter { $0.row.timing?.isPlanned != true }.map(\.meal))
        let plannedWindows = page.items.compactMap { item -> AdaptiveMealPlan.Suggestion? in
            guard item.row.timing?.isPlanned == true, let date = item.row.timing?.selectedAt else { return nil }
            return .init(meal: item.meal, start: date.addingTimeInterval(-3600), end: date.addingTimeInterval(3600), nutrition: .init())
        }
        let time = day == Day(now) ? now : calendar.date(bySettingHour: calendar.component(.hour, from: now), minute: calendar.component(.minute, from: now), second: 0, of: day.date)!
        return choose(windows: plan.suggestions + plannedWindows, eaten: eaten, at: time)
    }
}
