import Foundation

struct SearchEvidence: Codable, Equatable, Sendable {
    var version = "hybrid-v5"
    var query: String
    var lexical: Double
    var fuzzy: Double
    var semantic: Double?
    var lexicalRank: Int?
    var fuzzyRank: Int?
    var semanticRank: Int?
    var fusion: Double = 0
    var coverage: Double
    var corrections: [String]
    var conflicts: [String]
    var missing: [String]
    var historyBonus: Double = 0
    var recognizedCoverage: Double?
    var unrecognizedTerms: [String]?
    var semanticContribution: Double?
    var scoreBeforeConstraints: Double?
    var selectionRule: String?
    var identityCoverage: Double?
    var lexicalEdits: Int?
}

/// A cached immutable snapshot; no I/O or UI mutation during ranking.
struct SearchIndex: Sendable {
    struct Document: Sendable {
        var name: String
        var identity: String
        var nameWords: Set<String>
        var brandWords: Set<String>
        var manufacturerWords: Set<String>
        var words: Set<String>
        var grams: Set<String>
        var attributes: [String: String]
        var numbers: Set<String>
    }
    let products: [Product]
    let terms: [Set<String>]
    let documents: [Document]
    let frequencies: [String: Int]
    let averageLength: Double
    let fingerprint: String
    private let compounds: Set<String>

    private static func compact(_ value: String, vocabulary: Set<String>) -> String {
        let tokens = MealMatcher.normalize(value).split(separator: " ").map(String.init)
        let protected: Set<String> = ["не", "без", "с", "со", "и", "или"]
        var out: [String] = []; var i = 0
        while i < tokens.count {
            var length = 1
            if tokens.count - i >= 2 {
                for n in stride(from: min(3, tokens.count - i), through: 2, by: -1) {
                    let part = tokens[i..<(i+n)]
                    if part.allSatisfy({ $0.allSatisfy(\.isLetter) && !protected.contains($0) }),
                       vocabulary.contains(part.joined()) { length = n; break }
                }
            }
            out.append(tokens[i..<(i+length)].joined()); i += length
        }
        return out.joined(separator: " ")
    }
    static func grams(_ value: String) -> Set<String> {
        let chars = Array(value.replacingOccurrences(of: " ", with: ""))
        guard chars.count >= 3 else { return Set([String(chars)]) }
        return Set((0...(chars.count-3)).map { String(chars[$0..<($0+3)]) })
    }
    static func dice(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        return 2 * Double(a.intersection(b).count) / Double(a.count + b.count)
    }
    /// Optimal string alignment distance, bounded before allocating a matrix.
    static func editDistance(_ a: String, _ b: String, limit: Int = 2) -> Int {
        let x = Array(a), y = Array(b)
        guard abs(x.count-y.count) <= limit else { return limit+1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var older = Array(0...y.count), previous = older
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j]+1, current[j-1]+1, previous[j-1]+(x[i-1] == y[j-1] ? 0 : 1))
                if i > 1 && j > 1 && x[i-1] == y[j-2] && x[i-2] == y[j-1] {
                    current[j] = min(current[j], older[j-2]+1)
                }
            }
            older = previous; previous = current
        }
        return previous[y.count]
    }
    static func percentages(_ text: String) -> Set<String> {
        Set(MealMatcher.normalize(text).split(separator: " ").filter { $0.hasSuffix("%") }.map(String.init))
    }
    static func attributes(_ text: String) -> [String: String] {
        let words = MealMatcher.normalize(text).split(separator: " ").map(String.init)
        var result: [String: String] = [:]
        let percent = percentages(text)
        if percent.count == 1 { result["fat"] = percent.first }
        for word in words {
            if word.hasPrefix("варен") || word.hasPrefix("отвар") { result["state"] = "boiled" }
            if word.hasPrefix("сырой") || word.hasPrefix("сырая") || word.hasPrefix("сырые") || word.hasPrefix("сух") { result["state"] = "raw" }
            if word.hasPrefix("жарен") || word.hasPrefix("жаренн") { result["state"] = "fried" }
            if word.hasPrefix("сушен") { result["state"] = "dried" }
            if word.hasPrefix("безлактоз") { result["lactose"] = "without" }
            if word.hasPrefix("обезжир") { result["fatKind"] = "skimmed" }
        }
        for i in words.indices where i+1 < words.count && ["без", "с"].contains(words[i]) {
            let sign = words[i] == "без" ? "without" : "with"
            if words[i+1].hasPrefix("сахар") { result["sugar"] = sign }
            if words[i+1].hasPrefix("лактоз") { result["lactose"] = sign }
            if words[i+1].hasPrefix("сол") { result["salt"] = sign }
        }
        return result
    }
    init(products: [Product]) {
        self.products = products
        let identities = products.map { [$0.name, $0.brand, $0.manufacturer ?? ""].joined(separator: " ") }
        var vocabulary = Set(identities.flatMap { MealMatcher.normalize($0).split(separator: " ").map(String.init) }.filter { $0.count >= 4 && $0.allSatisfy(\.isLetter) })
        for product in products {
            let brand = MealMatcher.normalize(product.brand).split(separator: " ").map(String.init)
            if (2...3).contains(brand.count), brand.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isLetter) && !["без", "не", "или"].contains($0) }) { vocabulary.insert(brand.joined()) }
        }
        compounds = vocabulary
        documents = products.map { product in
            let name = Self.compact(product.name, vocabulary: vocabulary)
            let brand = Self.compact(product.brand, vocabulary: vocabulary)
            let manufacturer = Self.compact(product.manufacturer ?? "", vocabulary: vocabulary)
            let identity = [name, brand, manufacturer].filter { !$0.isEmpty }.joined(separator: " ")
            return Document(name: MealMatcher.searchPhrase(name), identity: MealMatcher.searchPhrase(identity),
                nameWords: MealMatcher.searchWords(name), brandWords: MealMatcher.searchWords(brand),
                manufacturerWords: MealMatcher.searchWords(manufacturer), words: MealMatcher.searchWords(identity),
                grams: Self.grams(name + brand), attributes: Self.attributes(product.name),
                numbers: Set(MealMatcher.normalize(identity).split(separator: " ").filter { $0.contains(where: \.isNumber) }.map(String.init)))
        }
        terms = documents.map(\.words)
        var counts: [String: Int] = [:]
        for words in terms { for word in words { counts[word, default: 0] += 1 } }
        frequencies = counts
        averageLength = max(1, Double(terms.reduce(0) { $0+$1.count }) / Double(max(1, products.count)))
        // Stable FNV fingerprint for diagnostics; not a security hash.
        var hash: UInt64 = 14695981039346656037
        for value in products.map({ $0.id + "|" + $0.name + "|" + $0.brand + "|" + ($0.manufacturer ?? "") }) {
            for byte in (value + "\n").utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        }
        fingerprint = String(hash, radix: 16)
    }

    func rank(_ phrase: String, history: [MatchHistory], now: Date = Date(),
              restrictingTo allowed: Set<String>? = nil,
              usage: [MatchHistory] = [], semantic: [String: Double] = [:]) -> [ProductCandidate] {
        let clean = MealMatcher.searchPhrase(Self.compact(phrase, vocabulary: compounds))
        let query = MealMatcher.searchWords(clean)
        guard !query.isEmpty else { return [] }
        let attrs = Self.attributes(phrase)
        let percent = Self.percentages(phrase)
        let disputedPercent = percent.count > 1
        let numbers = Set(clean.split(separator: " ").filter { $0.contains(where: \.isNumber) && !(disputedPercent && $0.hasSuffix("%")) }.map(String.init))
        let reference = MealMatcher.normalize(phrase).range(of: #"\b(который|которую|купил|купила|вчера|тот|та|не|вместо|вернее|нет)\b"#, options: .regularExpression) != nil
        func weight(_ word: String) -> Double { log(1 + (Double(products.count-(frequencies[word] ?? 0))+0.5)/(Double(frequencies[word] ?? 0)+0.5)) }
        let denominator = max(0.001, query.reduce(0) { $0+weight($1) })
        let queryGrams = Self.grams(clean)
        let protected: Set<String> = ["без", "не"]
        var matches: [String: [(String, Int)]] = [:]
        let vocabulary = Set(documents.flatMap { $0.words })
        for q in query {
            var options: [(String, Int)] = []
            let limit = q.count >= 7 ? 2 : 1
            for word in vocabulary {
                if q == word { options.append((word, 0)); continue }
                guard q.count >= 4, word.count >= 4, !protected.contains(q), !protected.contains(word),
                      abs(q.count-word.count) <= limit else { continue }
                // At most limit edits can introduce previously absent characters.
                guard Set(q).subtracting(Set(word)).count <= limit else { continue }
                let distance = Self.editDistance(q, word, limit: limit)
                if distance <= limit { options.append((word,distance)) }
            }
            matches[q] = options.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        }
        // Unknown transcript noise has no catalogue evidence. Keep it in missing
        // (so it still blocks auto-selection), but not in the ranking denominator.
        let recognized = query.filter { !(matches[$0] ?? []).isEmpty }
        let recognizedDenominator = max(0.001, recognized.reduce(0) { $0 + weight($1) })
        let unrecognized = query.subtracting(recognized).sorted()
        func fuzzyMatch(_ q: String, _ words: Set<String>) -> (String, Int)? {
            matches[q]?.first { words.contains($0.0) }
        }
        // A spoken known brand excludes confident substitution by another brand.
        let mentionedBrands = Set(documents.filter { !$0.brandWords.isEmpty && $0.brandWords.allSatisfy { brandWord in query.contains { q in matches[q]?.contains(where: { $0.0 == brandWord }) == true } } }.map { $0.brandWords.sorted().joined(separator:" ") })
        var candidates: [ProductCandidate] = []
        for index in products.indices {
            let p = products[index], d = documents[index]
            if let allowed, !allowed.contains(p.id) { continue }
            let common = query.intersection(d.words)
            var matched: Set<String> = [], corrections: [String] = [], used: Set<String> = []
            var edits = 0
            var correctedPairs: [(String, String, Int)] = []
            // Exact matches consume their token before approximate matching.
            for q in query.sorted(by: { (common.contains($0) ? 0 : 1, $0) < (common.contains($1) ? 0 : 1, $1) }) {
                if let (word, cost) = fuzzyMatch(q, d.words.subtracting(used)) {
                    used.insert(word); matched.insert(q); edits += cost
                    if cost > 0 { corrections.append(q + "→" + word); correctedPairs.append((q, word, cost)) }
                }
            }
            let coverage = matched.reduce(0) { $0+weight($1) } / denominator
            let recognizedCoverage = matched.reduce(0) { $0 + weight($1) } / recognizedDenominator
            let lexical = common.reduce(0.0) { score, word in
                let field = d.nameWords.contains(word) ? 1.0 : d.brandWords.contains(word) ? 1.1 : 0.3
                return score + field * weight(word)*2.2/(1+1.2*(0.25+0.75*Double(d.words.count)/averageLength))
            }
            let fuzzy = 0.8*coverage + 0.2*Self.dice(queryGrams, d.grams)
            let vector = semantic[p.id].flatMap { $0.isFinite ? min(1, max(-1, $0)) : nil }
            guard !common.isEmpty || recognizedCoverage >= 0.5 || (vector ?? 0) >= 0.72 else { continue }
            var conflicts: [String] = [], missing = Array(query.subtracting(matched)).sorted()
            for (key, value) in attrs {
                if let actual = d.attributes[key], actual != value { conflicts.append(key + ":" + value + "≠" + actual) }
                else if d.attributes[key] == nil { missing.append("признак:" + key) }
            }
            if disputedPercent, let fat = d.attributes["fat"], !percent.contains(fat) {
                conflicts.append("процент вне произнесённых вариантов")
            }
            if !numbers.isSubset(of: d.numbers) { conflicts.append("числовые признаки") }
            if !mentionedBrands.isEmpty && !mentionedBrands.contains(d.brandWords.sorted().joined(separator: " ")) { conflicts.append("марка") }
            let complete = matched == query && conflicts.isEmpty && missing.isEmpty
            let identityWords = d.nameWords.union(d.brandWords)
            let exact = d.name == clean || d.identity == clean
            let equivalent = identityWords == query && numbers.isSubset(of: d.numbers)
            let extraAttributes = d.attributes.keys.contains { attrs[$0] == nil }
            // Same bounded semantic contribution for every candidate; adding
            // lexical evidence can never switch to a lower scoring formula.
            let semanticContribution = max(0, min(12, ((vector ?? 0) - 0.72) / 0.28 * 12))
            var score = 48*recognizedCoverage + min(8, lexical) + min(6, fuzzy*6)
            if complete { score = 82 - Double(min(4, edits))*4 - Double(min(4,d.words.subtracting(used).count))*3 }
            if equivalent { score = 100 }
            if exact { score = 110 }
            score += semanticContribution
            let scoreBeforeConstraints = score
            if !conflicts.isEmpty { score = min(49, score-30) }
            if !missing.isEmpty { score = min(74,score) }
            var bonus = 0.0
            if complete && !reference {
                if let h = history.filter({ $0.product.id == p.id && MealMatcher.searchPhrase($0.phrase) == MealMatcher.searchPhrase(phrase) }).max(by: { $0.lastUsed < $1.lastUsed }) {
                    bonus += min(8, Double(h.count))*exp(-max(0,now.timeIntervalSince(h.lastUsed))/(30*86400))
                }
                if let h = usage.first(where: { $0.product.id == p.id }) {
                    bonus += min(1.5, log1p(Double(h.count))*0.4)
                    if now.timeIntervalSince(h.lastUsed) < 7*86400 { bonus += 1.5 }
                }
            }
            if p.preparedBatchID != nil, complete, conflicts.isEmpty, missing.isEmpty { bonus += 4 }
            score += min(10,bonus)
            if disputedPercent {
                missing.append("противоречивые проценты: " + percent.sorted().joined(separator: ", "))
                score = min(74, score)
            }
            // One name typo is safe only with exact brand evidence and the full
            // catalogue identity covered. Global score/margin checks still apply.
            let brandedTypo = edits == 1 && corrections.count == 1 &&
                !d.brandWords.isEmpty && d.brandWords.isSubset(of: query) &&
                identityWords.isSubset(of: used) && query.count == identityWords.count
            // A spelling variant can be supported by independent name anchors and
            // semantic agreement. Neither a high cosine nor a lone candidate suffices.
            let fullIdentity = identityWords.isSubset(of: used) && query.count == identityWords.count
            let nameAnchor = !common.intersection(d.nameWords).filter { $0.count >= 3 }.isEmpty
            let boundedVariant = correctedPairs.count == 1 && correctedPairs.allSatisfy { q, word, cost in
                !vocabulary.contains(q) && min(q.count, word.count) >= 5 &&
                    Double(cost) / Double(max(q.count, word.count)) <= 0.30
            }
            let supportedVariant = fullIdentity && nameAnchor && boundedVariant &&
                d.brandWords.isSubset(of: query) && (vector ?? 0) >= 0.88
            let eligible = !disputedPercent && complete && !reference && !extraAttributes && (exact || equivalent || brandedTypo || supportedVariant)
            let selectionRule = !conflicts.isEmpty || disputedPercent ? "blocked:conflicting-attributes" :
                !missing.isEmpty ? "blocked:missing-evidence" : reference ? "blocked:reference" :
                extraAttributes ? "blocked:unspecified-attributes" :
                exact ? "exact" : equivalent ? "equivalent" : brandedTypo ? "branded-typo" :
                supportedVariant ? "supported-name-variant" : "blocked:insufficient-identity"
            let reason = !conflicts.isEmpty ? "Не совпадает: " + conflicts.joined(separator:", ") :
                !missing.isEmpty ? "Уточните: " + missing.joined(separator:", ") :
                reference ? "Уточните, какой продукт" :
                supportedVariant ? "Название сопоставлено по словам и смыслу" :
                !corrections.isEmpty ? "Похожее написание: " + corrections.joined(separator:", ") :
                exact || equivalent ? "Совпадает название и признаки" : "Проверьте разновидность продукта"
            candidates.append(ProductCandidate(product:p,score:score,reason:reason,automaticEligible:eligible,
                evidence: SearchEvidence(query:clean,lexical:lexical,fuzzy:fuzzy,semantic:vector,coverage:coverage,
                    corrections:corrections,conflicts:conflicts,missing:missing,historyBonus:bonus, recognizedCoverage:recognizedCoverage,
                    unrecognizedTerms:unrecognized, semanticContribution:semanticContribution, scoreBeforeConstraints:scoreBeforeConstraints, selectionRule:selectionRule,
                    identityCoverage:Double(identityWords.intersection(used).count) / Double(max(1,identityWords.count)), lexicalEdits:edits)))
        }
        let lexicalOrder = candidates.filter { ($0.evidence?.lexical ?? 0) > 0 }.sorted { ($0.evidence?.lexical ?? 0) > ($1.evidence?.lexical ?? 0) }.map(\.id)
        let fuzzyOrder = candidates.filter { ($0.evidence?.coverage ?? 0) > 0 }.sorted { ($0.evidence?.fuzzy ?? 0) > ($1.evidence?.fuzzy ?? 0) }.map(\.id)
        let semanticOrder = candidates.filter { $0.evidence?.semantic != nil }.sorted { ($0.evidence?.semantic ?? 0) > ($1.evidence?.semantic ?? 0) }.map(\.id)
        for i in candidates.indices {
            let id = candidates[i].id
            let l = lexicalOrder.firstIndex(of:id).map { $0+1 }, f = fuzzyOrder.firstIndex(of:id).map { $0+1 }, v = semanticOrder.firstIndex(of:id).map { $0+1 }
            let fusion = [l,f,v].compactMap { $0 }.reduce(0.0) { $0+1/(60+Double($1)) }
            candidates[i].evidence?.lexicalRank=l; candidates[i].evidence?.fuzzyRank=f; candidates[i].evidence?.semanticRank=v; candidates[i].evidence?.fusion=fusion
            // Bounded tie-breaker; evidence/attribute rules dominate RRF.
            candidates[i].score += min(3,fusion*60)
        }
        return candidates.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }
}
