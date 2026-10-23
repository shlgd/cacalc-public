import Foundation

/// Commands are recognized before the food-word filter, on complete words only.
enum MealVoiceCommand {
    enum Part: Equatable { case text(String), delete, stop }
    static func parts(_ text: String) -> [Part] {
        let source = text as NSString
        let pattern = try! NSRegularExpression(pattern: #"(?iu)\b(удалить|стоп)\b"#)
        var result: [Part] = []
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result.append(.text(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            result.append(source.substring(with: match.range).lowercased() == "стоп" ? .stop : .delete)
            cursor = NSMaxRange(match.range)
        }
        result.append(.text(source.substring(from: cursor)))
        return result
    }
    static func isStandalone(_ text: String) -> Bool {
        let tokens = text.lowercased().split { !$0.isLetter }
        return tokens.count == 1 && (tokens[0] == "удалить" || tokens[0] == "стоп")
    }
    static func preview(_ text: String) -> String {
        if case let .text(prefix) = parts(text).first { return prefix }
        return ""
    }
}

/// Final ASR phrases, not unstable token hypotheses. Incomplete pairs survive pauses.
enum LiveMealParser {
    struct Result: Sendable { var rows: [MealRow]; var pending: String }
    /// A completed unit ends a semantic position without ending audio capture.
    /// Parse each completed prefix before unrelated later speech can reject it.
    static func semantic(_ text: String, final: Bool = false) -> Result {
        let source = text as NSString
        let units = try! NSRegularExpression(pattern: #"(?iu)\b(?:граммов|грамма|грамм|гр|г)\b"#)
        var end = 0
        var rows: [MealRow] = []
        let unitMatches = units.matches(in: text, range: NSRange(location: 0, length: source.length))
        for unit in unitMatches {
            let next = NSMaxRange(unit.range)
            let piece = source.substring(with: NSRange(location: end, length: next - end))
            let parsed = parse(piece)
            guard !parsed.rows.isEmpty, parsed.pending.isEmpty,
                  parsed.rows.allSatisfy({ $0.amount != nil }) else { continue }
            rows += parsed.rows
            end = next
        }
        let tail = source.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines)
        // Weight-first input: after «350 грамм» the product can grow from
        // «хлопьев» to «кукурузных хлопьев Любятово». Keep that row revisable.
        if rows.isEmpty, !unitMatches.isEmpty {
            let parsed = parse(text)
            if !parsed.rows.isEmpty, parsed.rows.allSatisfy({ $0.amount != nil }) { return parsed }
        }
        if final {
            let parsed = parse(tail)
            rows += parsed.rows
            return Result(rows: rows, pending: parsed.pending)
        }
        return Result(rows: rows, pending: tail)
    }
    struct Preview {
        var rows: [MealRow]
        var title: String
    }
    /// Revisable display only: never persists a row or contributes nutrition.
    static func preview(_ text: String) -> Preview {
        let parsed = parse(text)
        var rows = parsed.rows
        let tail = parsed.pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else {
            return Preview(rows: rows, title: rows.isEmpty ? "Слушаю продукт и вес" : "Проверяю продукт и вес")
        }
        let source = tail.lowercased().replacingOccurrences(of: "ё", with: "е") as NSString
        let words = lexer.matches(in: source as String, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
        let units: Set<String> = ["г", "гр", "грамм", "грамма", "граммов"]
        var names: [String] = [], amount: Decimal?
        var index = 0
        while index < words.count {
            if let number = RussianLabelNumber.read(words, at: index) {
                // Percentages belong to the product's name, not to its weight.
                if number.end < words.count, words[number.end] == "%" || words[number.end].hasPrefix("процент") {
                    names += words[index...number.end]; index = number.end + 1; continue
                }
                if let value = number.value, value > 0, value <= 10_000, amount == nil { amount = value }
                else { return Preview(rows: rows, title: "Уточните продукт и вес") }
                index = number.end; continue
            }
            if !units.contains(words[index]) { names.append(words[index]) }
            index += 1
        }
        let name = filteredName(names)
        // A complete but rejected pair (correction/unsupported unit) isn't a new card.
        if amount != nil && !name.isEmpty { return Preview(rows: rows, title: "Уточните продукт и вес") }
        if !name.isEmpty || amount != nil {
            rows.append(MealRow(food: name, quantity: amount.map { Numbers.string($0) } ?? "", unit: amount == nil ? nil : .g))
        }
        return Preview(rows: rows, title: !name.isEmpty ? "Скажите вес" : (amount != nil ? "Скажите продукт" : "Слушаю продукт и вес"))
    }
    private static func filteredName(_ words: [String]) -> String {
        var output: [String] = []
        var i = 0
        while i < words.count {
            if let number = RussianLabelNumber.read(words, at: i),
               let value = number.value, number.end < words.count,
               words[number.end] == "%" || words[number.end].hasPrefix("процент") {
                output.append(Numbers.string(value) + "%")
                i = number.end + 1
            } else {
                output.append(words[i]); i += 1
            }
        }
        return FoodWordFilter.apply(output.joined(separator: " ")).text
    }
    private static let lexer = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?|[\p{L}]+|[^\s]"#)
    static func parse(_ text: String) -> Result {
        let source = text.lowercased().replacingOccurrences(of: "ё", with: "е") as NSString
        if text.range(of: #"[-−]\s*\d"#, options: .regularExpression) != nil { return Result(rows: [], pending: text) }
        let words = lexer.matches(in: source as String, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
        let grams: Set<String> = ["г", "гр", "грамм", "грамма", "граммов"]
        func name(_ slice: ArraySlice<String>) -> String { filteredName(Array(slice)) }
        // Units not supported by this pilot must never silently become grams.
        guard !words.contains(where: { ["нет", "не", "вместо", "вернее", "минус", "килограмм", "килограмма", "кг", "мл", "миллилитров", "миллилитр", "миллилитра", "литр", "литра", "литров", "килограммов", "штук", "штуки", "штука", "шт", "порции", "порция", "порций"].contains($0) }) else { return Result(rows: [], pending: text) }
        var spans: [(start: Int, end: Int, value: Decimal, explicit: Bool)] = []
        var i = 0
        while i < words.count {
            guard let number = RussianLabelNumber.read(words, at: i) else { i += 1; continue }
            let end = number.end
            if end < words.count, words[end] == "%" || words[end].hasPrefix("процент") { i = end + 1; continue }
            guard let value = number.value, value > 0, value <= 10_000 else { return Result(rows: [], pending: text) }
            let explicit = end < words.count && grams.contains(words[end])
            spans.append((i, explicit ? end + 1 : end, value, explicit)); i = explicit ? end + 1 : end
        }
        func damagedWeightEnd(_ end: Int) -> Int? {
            guard end < words.count else { return nil }
            let next = words[end]
            let roots = ["одн", "дв", "тр", "четыр", "пят", "шест", "сем", "восем", "девят", "десят", "сорок", "сто"]
            let fused = next.contains("грам") && roots.contains(where: { next.hasPrefix($0) })
            let beforeUnit = end + 1 < words.count && grams.contains(words[end + 1])
            return fused || beforeUnit ? end + (beforeUnit ? 2 : 1) : nil
        }
        // A number in a name (brand, fat percentage) isn't an additional serving mass.
        if spans.contains(where: \.explicit) { spans = spans.filter { $0.explicit || damagedWeightEnd($0.end) != nil } }
        guard let first = spans.first else { return Result(rows: [], pending: text) }
        var rows: [MealRow] = []
        let amountFirst = name(words[..<first.start]).isEmpty
        var consumed = 0
        for index in spans.indices {
            let span = spans[index]
            let from = amountFirst ? span.end : consumed
            let to = amountFirst ? (index + 1 < spans.count ? spans[index + 1].start : words.count) : span.start
            let food = name(words[from..<to])
            guard food.contains(where: \.isLetter) else { break }
            // A recognized prefix is not a complete weight if an ASR-damaged unit
            // or another word before the unit follows it (e.g. «сто пятьдеграмм»).
            // Keep one food with unknown mass; never create a food from the suffix.
            let damagedEnd = !amountFirst && !span.explicit ? damagedWeightEnd(span.end) : nil
            if let damagedEnd {
                rows.append(MealRow(food: food, unit: .g, matchAttention: "Не удалось распознать вес"))
                consumed = damagedEnd
            } else {
                rows.append(MealRow(food: food, quantity: Numbers.string(span.value), unit: .g))
                consumed = amountFirst ? to : span.end
            }
        }
        return Result(rows: rows, pending: name(words[consumed...]))
    }
}

/// Incremental PCM16 WAV reader. AVAudioRecorder updates RIFF/data sizes only on close;
/// while recording the actual file length is authoritative. Never assumes a 44-byte header.
enum LiveWave {
    struct Window: Sendable { let samples: [Float]; let totalSamples: Int }
    /// Seek to the unread region; long cooking sessions never load the whole WAV.
    static func read(_ url: URL, from sample: Int, finalized: Bool, limit: Int = 256_000) throws -> Window {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        func readAt(_ offset: UInt64, count: Int) throws -> [UInt8] {
            try handle.seek(toOffset: offset)
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        }
        func tag(_ bytes: [UInt8], _ i: Int) -> String { String(bytes: bytes[i..<i + 4], encoding: .ascii) ?? "" }
        func u16(_ bytes: [UInt8], _ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ bytes: [UInt8], _ i: Int) -> Int { u16(bytes, i) | u16(bytes, i + 2) << 16 }
        let header = try readAt(0, count: 12)
        guard header.count == 12 else { return Window(samples: [], totalSamples: 0) }
        guard tag(header, 0) == "RIFF", tag(header, 8) == "WAVE" else { throw FoodError.database("Неподдерживаемый формат живой записи.") }
        var offset: UInt64 = 12, valid = false
        while offset + 8 <= length {
            let chunk = try readAt(offset, count: 8)
            guard chunk.count == 8 else { break }
            let size = UInt64(u32(chunk, 4)), start = offset + 8
            if tag(chunk, 0) == "fmt " {
                let format = try readAt(start, count: 16)
                guard format.count == 16 else { break }
                valid = u16(format, 0) == 1 && u16(format, 2) == 1 && u32(format, 4) == 16_000 && u16(format, 14) == 16
            }
            if tag(chunk, 0) == "data" {
                guard valid else { throw FoodError.database("Живая запись ожидает PCM16, 16 кГц, моно.") }
                let end = finalized ? min(length, start + size) : length
                let total = Int((end - start) / 2)
                guard sample >= 0, sample < total else { return Window(samples: [], totalSamples: total) }
                let bytes = try readAt(start + UInt64(sample) * 2, count: min(limit, total - sample) * 2)
                let floats = stride(from: 0, to: bytes.count - 1, by: 2).map { Float(Int16(bitPattern: UInt16(u16(bytes, $0)))) / 32768 }
                return Window(samples: floats, totalSamples: total)
            }
            offset = start + size + size % 2
        }
        return Window(samples: [], totalSamples: 0)
    }
    static func samples(_ data: Data, finalized: Bool = false) throws -> [Float] {
        let bytes = [UInt8](data)
        func tag(_ at: Int) -> String { String(bytes: bytes[at..<at + 4], encoding: .ascii) ?? "" }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 12 else { return [] }
        guard tag(0) == "RIFF", tag(8) == "WAVE" else { throw FoodError.database("Неподдерживаемый формат живой записи.") }
        var offset = 12, valid = false
        while offset + 8 <= bytes.count {
            let kind = tag(offset), size = u32(offset + 4), start = offset + 8
            if kind == "fmt " {
                guard size >= 16, start + 16 <= bytes.count else { return [] }
                valid = u16(start) == 1 && u16(start + 2) == 1 && u32(start + 4) == 16_000 && u16(start + 14) == 16
            }
            if kind == "data" {
                guard valid else { throw FoodError.database("Живая запись ожидает PCM16, 16 кГц, моно.") }
                let end = finalized ? min(bytes.count, start + size) : bytes.count
                guard end > start else { return [] }
                return stride(from: start, to: end - 1, by: 2).map { Float(Int16(bitPattern: UInt16(u16($0)))) / 32768 }
            }
            guard size <= bytes.count - start else { return [] }
            offset = start + size + size % 2
        }
        return []
    }
}

/// Endpoint detector, not a claim of semantic speech detection. Keeps pre-roll and
/// closes only after 1.2 s of quiet; ASR still validates whether speech exists.
/// Preserve every real sample; only satisfy the decoder's minimum input length.
enum LiveASRInput {
    static func padded(_ samples: [Float], minimum: Int = 4_800) -> [Float] {
        guard !samples.isEmpty, samples.count < minimum else { return samples }
        return samples + Array(repeating: 0, count: minimum - samples.count)
    }
}

/// Evidence from this audio phrase only, never a permanent product alias.
struct LiveIdentityMemory {
    private var identity: [String] = []
    mutating func reset() { identity = [] }
    mutating func resolve(_ text: String, products: [Product]) -> String {
        let clean = MealMatcher.normalize(text)
        let words = clean.split(separator: " ").map(String.init)
        let corrections: Set<String> = ["нет", "не", "вместо", "вернее", "точнее", "удалить", "стоп"]
        guard corrections.isDisjoint(with: words) else { reset(); return text }
        let identities = products.filter { !$0.brand.isEmpty }.map {
            MealMatcher.normalize($0.name + " " + $0.brand).split(separator: " ").map(String.init)
        }.filter { $0.count >= 2 }
        let exact = identities.filter { words.starts(with: $0) }
        if let best = exact.max(by: { $0.count < $1.count }) {
            identity = best
            return text
        }
        guard identity.count >= 2, words.count >= identity.count else { return text }
        let n = identity.count
        // Recover only a damaged final word; all preceding words must agree.
        // A different complete catalogue identity above always wins.
        let partial = words[n - 1], full = identity[n - 1]
        func nearby(_ candidate: String) -> Bool {
            guard partial.count >= 4, candidate.prefix(4) == partial.prefix(4) else { return false }
            return (candidate.count > partial.count && candidate.count - partial.count <= 3 && candidate.hasPrefix(partial)) ||
                SearchIndex.editDistance(partial, candidate, limit: 2) <= 2
        }
        guard Array(words.prefix(n - 1)) == Array(identity.dropLast()), nearby(full),
              identities.filter({ $0.count == n && Array($0.dropLast()) == Array(identity.dropLast()) && nearby($0.last!) }).count == 1
        else { reset(); return text }
        var restored = words
        restored[n - 1] = full
        return restored.joined(separator: " ")
    }
}

struct LiveMealEndpoint {
    var cursor: Int
    private var start: Int?
    private var lastSound = 0
    private var activeSamples = 0
    private(set) var rejectedTransientCount = 0
    // Exclude pre-roll and trailing quiet from the activity requirement.
    // This rejects isolated clicks; it is not a full speech/noise classifier.
    private var hasActivity: Bool { activeSamples >= 960 }
    init(cursor: Int = 0) { self.cursor = cursor }
    // A revisable preview while speech is still underway; it never advances
    // the persisted phrase checkpoint or creates a meal row.
    var previewRange: Range<Int>? {
        guard let start, hasActivity, lastSound - start >= 12_800 else { return nil }
        return start..<lastSound
    }
    // Probe a short isolated utterance without changing normal food boundaries.
    var commandRange: Range<Int>? {
        guard let start, hasActivity, cursor - lastSound >= 4_000,
              lastSound - start <= 40_000 else { return nil }
        return start..<lastSound
    }
    var discardableSamples: Int { start ?? max(0, cursor - 3200) }
    mutating func discardPrefix(_ count: Int) {
        cursor -= count
        if let value = start { start = value - count }
        lastSound = max(0, lastSound - count)
    }
    mutating func next(_ samples: [Float], finished: Bool) -> Range<Int>? {
        let frame = 320
        while cursor + frame <= samples.count {
            let end = cursor + frame
            let rms = sqrt(samples[cursor..<end].reduce(Float(0)) { $0 + $1 * $1 } / Float(frame))
            if rms > 0.008 {
                if start == nil { start = max(cursor - 3200, 0) }
                activeSamples += frame
                lastSound = end
            }
            cursor = end
            if let begin = start, cursor - lastSound >= 19_200 {
                let accepted = hasActivity
                start = nil; activeSamples = 0
                if accepted { return begin..<cursor }
                rejectedTransientCount += 1
            }
            // Never turn an elapsed-time limit into a speech boundary: this used
            // to split «триста грамм» into independent ASR calls after 12 seconds.
            // Longer audio is handled by the ASR library's overlapping windows.
        }
        if finished, let begin = start {
            let accepted = hasActivity
            start = nil; activeSamples = 0; cursor = samples.count
            if accepted { return begin..<samples.count }
            rejectedTransientCount += 1
        }
        return nil
    }
}

/// Text-only lattice: each edge contains ONE food span and ONE explicit quantity.
/// Audio endpoints and product ranking are deliberately outside this grammar.
enum MealPairParser {
    struct Lexicon: Sendable {
        let documents: [SearchIndex.Document]
        let numericNames: [[String]]
        let vocabulary: Set<String>
        let compounds: Set<String>
        let standalone: Set<String>
        let primaryFoods: Set<String>
        let nameSequences: [[String]]
        private static let states: Set<String> = [
            "сырой", "сырая", "сырое", "сырые", "вареный", "вареная", "вареное", "вареные",
            "отварной", "отварная", "отварное", "отварные", "сухой", "сухая", "сухое", "сухие",
            "свежий", "свежая", "свежее", "свежие"
        ]
        init(index: SearchIndex) {
            documents = index.documents
            numericNames = index.products.compactMap { product in
                let text = MealMatcher.normalize(product.name + " " + product.brand) as NSString
                let tokens = MealPairParser.lexer.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) }
                return tokens.contains(where: { $0.first?.isNumber == true }) && tokens.count > 1 ? tokens : nil
            }
            nameSequences = index.documents.flatMap { [Self.sequence($0.name), Self.sequence($0.identity)] }
            primaryFoods = Set(index.documents.flatMap { document in
                let text = document.name.lowercased().replacingOccurrences(of: "ё", with: "е") as NSString
                let tokens = MealPairParser.lexer.matches(in: text as String, range: NSRange(location: 0, length: text.length))
                    .map { text.substring(with: $0.range) }.filter { $0.first?.isLetter == true }
                return tokens.first(where: { !Self.states.contains($0) }).map { Array(MealMatcher.searchWords($0)) } ?? []
            })
            standalone = Set(index.documents.filter { $0.nameWords.count == 1 }.flatMap { $0.nameWords })
            vocabulary = Set(index.documents.flatMap { $0.nameWords })
            compounds = Set(index.products.flatMap { MealMatcher.normalize($0.name + " " + $0.brand).split(separator: " ").map(String.init) })
        }
        func couldBePercent(_ prefix: [String], value: Decimal) -> Bool {
            numericNames.contains { name in
                guard let i = name.firstIndex(where: { Decimal(string: $0) == value }),
                      i > 0, i + 1 < name.count, name[i + 1] == "%", prefix.count >= i else { return false }
                return Array(prefix.suffix(i)) == Array(name.prefix(i))
            }
        }
        func numericIdentityPositions(_ words: [String]) -> Set<Int> {
            var protected = Set<Int>()
            for start in words.indices {
                for name in numericNames {
                    var cursor = start
                    var positions = Set<Int>()
                    var matched = true
                    for token in name {
                        guard cursor < words.count else { matched = false; break }
                        if let expected = Decimal(string: token), token.first?.isNumber == true,
                           let number = RussianLabelNumber.read(words, at: cursor), number.value == expected {
                            positions.insert(cursor); cursor = number.end
                        } else if words[cursor] == token { cursor += 1 }
                        else { matched = false; break }
                    }
                    if matched { protected.formUnion(positions) }
                }
            }
            return protected
        }
        private static func sequence(_ text: String) -> [String] {
            return MealMatcher.searchPhrase(text).split(separator: " ").filter { !states.contains(String($0)) }.flatMap { MealMatcher.searchWords(String($0)).sorted() }
        }
        func protects(_ text: String) -> Bool {
            // Do not extend a protected name across preceding percentages or
            // adjectives: «1% сыр гауда» is not the catalog phrase «сыр гауда».
            guard text.first?.isLetter == true else { return false }
            let words = MealMatcher.searchPhrase(text).split(separator: " ").flatMap { MealMatcher.searchWords(String($0)).sorted() }
            guard words.count >= 2 else { return false }
            return nameSequences.contains { name in
                if words.count == 2, name.count == 2, Set(words) == Set(name) { return true }
                guard name.count >= words.count else { return false }
                // A catalog ingredient list isn't an independent compound name:
                // «сок яблоко огурец» must not bind separately weighed apple/cucumber.
                return Array(name.prefix(words.count)) == words
            }
        }
        func evidence(_ text: String) -> Int? {
            var tokens = text.split(separator: " ").map(String.init)
            guard tokens.first?.first?.isLetter == true else { return nil }
            var i = 0
            while i + 1 < tokens.count {
                let joined = tokens[i] + tokens[i + 1]
                if compounds.contains(joined) { tokens.replaceSubrange(i...i+1, with: [joined]) }
                else { i += 1 }
            }
            var tokenTerms: [String: Set<String>] = [:]
            func queryWords(_ words: [String]) -> Set<String> {
                var result = Set<String>()
                for token in words {
                    if let cached = tokenTerms[token] { result.formUnion(cached); continue }
                    let terms = Set(MealMatcher.searchWords(token).map { word in
                        if vocabulary.contains(word) { return word }
                        let close = vocabulary.filter { $0.count >= 4 && word.count >= 4 && SearchIndex.editDistance(word, $0, limit: 1) == 1 }
                        return close.count == 1 ? close.first! : word
                    })
                    tokenTerms[token] = terms
                    result.formUnion(terms)
                }
                return result
            }
            let query = queryWords(tokens)
            let numbers = Set(tokens.filter { $0.contains(where: \.isNumber) })
            let adjectiveEndings = ["ый", "ий", "ая", "яя", "ое", "ее", "ые", "ие", "ого", "его", "ую", "юю", "ыми", "ими"]
            let onlyModifiers = tokens.allSatisfy { token in
                token.contains(where: \.isNumber) || adjectiveEndings.contains(where: { token.hasSuffix($0) })
            }
            guard !query.isEmpty, !onlyModifiers || !query.isDisjoint(with: standalone) else { return nil }
            // Only standalone food names are evidence for TWO foods. Catalog
            // adjectives, brands and ingredients after «без/с/из» are not boundaries.
            let ingredientMarkers: Set<String> = ["без", "с", "со", "из"]
            guard !ingredientMarkers.contains(tokens[0]),
                  !ingredientMarkers.contains(tokens.last ?? "") else { return nil }
            let marker = tokens.firstIndex(where: { ingredientMarkers.contains($0) }) ?? tokens.count
            let mainTokens = Array(tokens.prefix(marker))
            let identity = queryWords(mainTokens)
            let mainName = queryWords(mainTokens.filter { !Self.states.contains($0) })
            let fullName = queryWords(tokens.filter { !Self.states.contains($0) })
            let anchors = mainName.intersection(standalone.union(primaryFoods))
            // Two main foods before a modifier still need a known compound name.
            // For «филе индейки с соусом», that name is the prefix, not the sauce.
            if anchors.count > 1 && !nameSequences.contains(where: { Set($0) == fullName || Set($0) == mainName }) { return nil }
            let coverage = documents.filter { !identity.isDisjoint(with: $0.nameWords) }.map {
                Double(identity.intersection($0.words).count) / Double(max(1, identity.count))
            }.max() ?? 0
            let hasName = coverage > 0
            // Prefer a complete contiguous name, including a previously unseen
            // brand/state. Product choice and attribute conflicts are checked later.
            return (hasName ? 100 : 15) + Int(coverage * 40) + min(query.count, 20) * 3 + numbers.count * 3

        }
    }
    struct Trace: Codable, Sendable {
        var version = "pair-lattice-v3"
        var source: String
        var decisions: [String] = []
        var alternatives: [[String]] = []
    }
    struct Output: Sendable {
        var result: LiveMealParser.Result
        var trace: Trace
    }
    private struct Atom {
        var text: String
        var amount: Decimal? = nil
        var unit: FoodUnit? = nil
    }
    private struct Edge {
        var start: Int
        var end: Int
        var food: String
        var amount: Decimal
        var unit: FoodUnit
        var score: Int
        var signature: String { "\(food)|\(amount)|\(unit.rawValue)" }
        var row: MealRow { MealRow(food: food, quantity: Numbers.string(amount), unit: unit) }
    }
    private struct Path {
        var edges: [Edge] = []
        var score: Int = 0
        var end: Int { edges.last?.end ?? 0 }
        var signature: String { edges.map(\.signature).joined(separator: ";") }
    }
    private static let lexer = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?|[\p{L}]+|[^\s]"#)
    private static let units: [String: FoodUnit] = [
        "gram": .g, "grams": .g, "g": .g, "г": .g, "гр": .g, "грамм": .g, "грамма": .g, "граммов": .g,
        "кг": .kg, "килограмм": .kg, "килограмма": .kg, "килограммов": .kg,
        "мл": .ml, "миллилитр": .ml, "миллилитра": .ml, "миллилитров": .ml,
        "л": .l, "литр": .l, "литра": .l, "литров": .l,
        "шт": .pc, "штука": .pc, "штуки": .pc, "штук": .pc,
        "порция": .portion, "порцию": .portion, "порции": .portion, "порций": .portion
    ]
    static func trailingBareNumber(_ text: String) -> Bool {
        let source = text.lowercased() as NSString
        let words = lexer.matches(in: text.lowercased(), range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }.filter { ![".", ",", "!", "?", ":", ";", "…"].contains($0) }
        return words.indices.contains { i in
            guard let number = RussianLabelNumber.read(words, at: i) else { return false }
            return number.value != nil && number.end == words.count
        }
    }
    static func analyze(_ text: String, lexicon: Lexicon, final: Bool = false) -> Output {
        let source = text.lowercased().replacingOccurrences(of: "ё", with: "е") as NSString
        let words = lexer.matches(in: source as String, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }.filter { ![".", ",", "!", "?", ":", ";", "…"].contains($0) }
        var groups: [[String]] = [[]]
        // Only an explicit command is a hard boundary. Punctuation is ASR decoration.
        for word in words {
            if ["дальше", "далее"].contains(word) { groups.append([]) }
            else { groups[groups.count - 1].append(word) }
        }
        var rows: [MealRow] = [], pending: [String] = []
        var trace = Trace(source: text)
        for (groupIndex, group) in groups.enumerated() {
            if group.isEmpty { continue }
            var atoms: [Atom] = []
            var index = 0
            var blocked = false
            let protectedNumbers = lexicon.numericIdentityPositions(group)
            while index < group.count {
                let word = group[index]
                if ["еще", "плюс", "+"].contains(word),
                   (index == 0 || atoms.last?.amount != nil),
                   RussianLabelNumber.read(group, at: index + 1) != nil {
                    // Do not erase an addition into an identical-weight repeat,
                    // including when the retained tail is parsed again later.
                    blocked = true
                    trace.decisions.append("group \(groupIndex): additive quantity requires clarification")
                    break
                }
                if (word == "от" && index + 1 < group.count && RussianLabelNumber.read(group, at: index + 1) != nil && group[index...].contains("до")) ||
                    (word == "по" && index + 1 < group.count && RussianLabelNumber.read(group, at: index + 1) != nil) {
                    blocked = true; break
                }
                if ["не", "нет", "вместо", "вернее", "минус"].contains(word) ||
                    ((word == "-" || word == "−") && index + 1 < group.count && group[index + 1].first?.isNumber == true) {
                    // A local correction is unambiguous only immediately after a weight.
                    if ["нет", "вернее"].contains(word), let last = atoms.last, last.amount != nil,
                       let replacement = RussianLabelNumber.read(group, at: index + 1),
                       let value = replacement.value, value > 0, value <= 10_000,
                       !(replacement.end < group.count && (group[replacement.end] == "%" || group[replacement.end].hasPrefix("процент"))) {
                        let explicit = replacement.end < group.count ? units[group[replacement.end]] : nil
                        atoms[atoms.count - 1] = Atom(text: Numbers.string(value) + " " + (explicit ?? last.unit!).title, amount: value, unit: explicit ?? last.unit)
                        index = replacement.end + (explicit == nil ? 0 : 1)
                        trace.decisions.append("group \(groupIndex): explicit local weight correction")
                        continue
                    }
                    blocked = true; break
                }
                if let number = RussianLabelNumber.read(group, at: index), let value = number.value {
                    if number.end < group.count, group[number.end] == "%" || group[number.end].hasPrefix("процент") {
                        atoms.append(Atom(text: Numbers.string(value) + "%")); index = number.end + 1; continue
                    }
                    if protectedNumbers.contains(index) {
                        atoms.append(Atom(text: Numbers.string(value)))
                        index = number.end; continue
                    }
                    if number.end < group.count, let unit = units[group[number.end]] {
                        guard value > 0, value <= 10_000 else { blocked = true; break }
                        // Only a trailing repeat can confirm the completed food.
                        // In «food 50 g 50 g next food», the second weight may
                        // belong to the next food, so the lattice must keep it.
                        let remaining = Array(group[(number.end + 1)...])
                        let hasFollowingName = remaining.indices.contains { position in
                            let token = remaining[position]
                            return token.first?.isLetter == true && units[token] == nil &&
                                RussianLabelNumber.read(remaining, at: position) == nil &&
                                !FoodWordFilter.apply(token).text.isEmpty
                        }
                        if [.g, .kg, .ml, .l].contains(unit), index > 0,
                           !hasFollowingName, atoms.dropLast().contains(where: { $0.amount == nil && $0.text.contains(where: \.isLetter) }),
                           units[group[index - 1]] == unit,
                           let previous = atoms.last, previous.amount == value, previous.unit == unit {
                            trace.decisions.append("group \(groupIndex): repeated explicit quantity \(Numbers.string(value)) \(unit.title)")
                            index = number.end + 1
                            continue
                        }
                        atoms.append(Atom(text: Numbers.string(value) + " " + unit.title, amount: value, unit: unit))
                        index = number.end + 1; continue
                    }
                    // Partial ASR numbers can still grow (сто → сто пятьдесят).
                    // At a pause/stop or before the next food, an unlabelled amount is grams.
                    if number.end == group.count, lexicon.couldBePercent(Array(group[..<index]), value: value) {
                        blocked = true; break
                    }
                    let closed = final || groupIndex < groups.count - 1 || number.end < group.count
                    let prefix = atoms.reversed().prefix { $0.amount == nil }
                    let hasNameBefore = prefix.contains { $0.text.contains(where: \.isLetter) }
                    let next = number.end < group.count ? group[number.end] : ""
                    let brokenUnit = next.contains("грам") && units[next] == nil
                    let unknownCount = ["яйца", "яйцо", "упаковка", "упаковки", "кусок", "куска", "кусочка", "ложка", "ложки", "стакан", "стакана"].contains(next)
                    guard closed, hasNameBefore, !brokenUnit, !unknownCount, value > 0, value <= 10_000 else { blocked = true; break }
                    atoms.append(Atom(text: Numbers.string(value) + " г", amount: value, unit: .g))
                    trace.decisions.append("group \(groupIndex): implicit grams")
                    index = number.end; continue
                }
                if ["порция", "порцию"].contains(word) {
                    atoms.append(Atom(text: "1 порция", amount: 1, unit: .portion))
                    index += 1; continue
                }
                if units[word] == .g { index += 1; continue }
                if !FoodWordFilter.apply(word).text.isEmpty {
                    atoms.append(Atom(text: word))
                }
                index += 1
            }
            let solved = solve(atoms, lexicon: lexicon, closed: final || groupIndex < groups.count - 1)
            var accepted = solved.0
            // Unrecognized trailing speech cannot undo an earlier complete pair.
            // A correction marker is retained rather than silently ignored.
            let tail = atoms.dropFirst(solved.1).map(\.text) + (blocked ? Array(group[index...]) : [])
            if blocked, ["не", "нет", "вместо", "вернее", "минус"].contains(group[index]), !accepted.isEmpty {
                accepted[accepted.count - 1].matchAttention = "Проверьте исправление в диктовке"
            }
            rows += accepted
            if !tail.isEmpty { pending.append(tail.joined(separator: " ")) }
            trace.decisions += solved.2
            trace.alternatives += solved.3
        }
        return Output(result: LiveMealParser.Result(rows: rows, pending: pending.joined(separator: " дальше ")), trace: trace)
    }
    private static func solve(_ atoms: [Atom], lexicon: Lexicon, closed: Bool) -> ([MealRow], Int, [String], [[String]]) {
        guard !atoms.isEmpty else { return ([], 0, [], []) }
        var protectedCuts = Set<Int>()
        for start in atoms.indices where atoms[start].amount == nil {
            var end = start + 1
            while end < atoms.count && atoms[end].amount == nil {
                end += 1
                let phrase = atoms[start..<end].map(\.text).joined(separator: " ")
                if lexicon.protects(phrase) { protectedCuts.formUnion((start + 1)..<end) }
            }
        }
        var evidence: [String: Int] = [:]
        var rejected: Set<String> = []
        func name(_ range: Range<Int>) -> (String, Int)? {
            guard !range.isEmpty, atoms[range].allSatisfy({ $0.amount == nil }) else { return nil }
            let text = atoms[range].map(\.text).joined(separator: " ")
            if rejected.contains(text) { return nil }
            if let score = evidence[text] { return (text, score) }
            guard let score = lexicon.evidence(text) else { rejected.insert(text); return nil }
            evidence[text] = score
            return (text, score)
        }
        var paths = Array(repeating: [Path](), count: atoms.count + 1)
        paths[0] = [Path()]
        for start in atoms.indices where !paths[start].isEmpty {
            var edges: [Edge] = []
            if let amount = atoms[start].amount, let unit = atoms[start].unit {
                var end = start + 1
                while end < atoms.count && atoms[end].amount == nil {
                    end += 1
                    if let (food, score) = name((start + 1)..<end) {
                        edges.append(Edge(start: start, end: end, food: food, amount: amount, unit: unit, score: score))
                    }
                }
            } else {
                var end = start
                while end < atoms.count && atoms[end].amount == nil { end += 1 }
                if end < atoms.count, let (food, score) = name(start..<end),
                   let amount = atoms[end].amount, let unit = atoms[end].unit {
                    edges.append(Edge(start: start, end: end + 1, food: food, amount: amount, unit: unit, score: score))
                }
            }
            for edge in edges where !protectedCuts.contains(edge.start) && !protectedCuts.contains(edge.end) {
                for path in paths[start] {
                    var next = path; next.edges.append(edge); next.score += 1000 + edge.score + (edge.end - edge.start) * 20
                    paths[edge.end].append(next)
                }
                paths[edge.end].sort { $0.score > $1.score }
                var seen = Set<String>()
                paths[edge.end] = Array(paths[edge.end].filter { seen.insert($0.signature).inserted }.prefix(2))
            }
        }
        let all = paths.flatMap { $0 }.filter { !$0.edges.isEmpty }.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.end > b.end
        }
        guard let best = all.first else { return ([], 0, ["no complete supported pair"], []) }
        // A second bare quantity can be a correction or the next unfinished food.
        // Do not invent a binding until the next food or an explicit command arrives.
        if best.end < atoms.count, atoms[best.end...].allSatisfy({ $0.amount != nil }) {
            let prefix = Array(best.edges.dropLast())
            return (prefix.map(\.row), prefix.last?.end ?? 0, ["unattached quantity: defer last pair"], [best.edges.map(\.signature)])
        }
        let second = all.dropFirst().first { candidate in
            guard candidate.signature != best.signature else { return false }
            // A shorter provisional spelling of the SAME last food isn't an
            // alternative quantity binding. Keep its longer contiguous identity.
            if candidate.edges.count == best.edges.count,
               zip(candidate.edges.dropLast(), best.edges.dropLast()).allSatisfy({ $0.signature == $1.signature }),
               let a = candidate.edges.last, let b = best.edges.last,
               a.start == b.start, a.amount == b.amount, a.unit == b.unit,
               b.food.hasPrefix(a.food + " ") { return false }
            return true
        }
        var edges = best.edges
        var decisions = ["best score \(best.score), end \(best.end)/\(atoms.count)"]
        if let second, second.edges.count == best.edges.count {
            // The two highest scores don't prove that a third interpretation
            // shares their prefix. Defer this whole unresolved speech group.
            edges = []
            decisions.append("multiple quantity bindings: score margin \(best.score - second.score) is not proof; group deferred")
        }
        if !closed, let last = edges.last, last.end == atoms.count, atoms[last.start].amount != nil {
            edges.removeLast()
            decisions.append("weight-first name remains open until pause, next pair or дальше")
        }
        let alternatives = [best, second].compactMap { $0 }.map { $0.edges.map(\.signature) }
        return (edges.map(\.row), edges.last?.end ?? 0, decisions, alternatives)
    }
}
