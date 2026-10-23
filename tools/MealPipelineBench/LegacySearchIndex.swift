import Foundation
/// Cached lexical index: BM25 orders related candidates; explicit identity governs auto-selection.
/// Scores are ranking points, never probabilities.
struct LegacySearchIndex: Sendable {
    let products: [Product]
    let terms: [Set<String>]
    let frequencies: [String: Int]
    let averageLength: Double
    private let compounds: Set<String>
    /// Merge only spellings evidenced by catalog tokens or complete brand names.
    private static func compactWords(_ text: String, compounds: Set<String>) -> String {
        let tokens = MealMatcher.normalize(text).split(separator: " ").map(String.init)
        let protected: Set<String> = ["не", "без", "с", "со", "и", "или"]
        var output: [String] = []
        var i = 0
        while i < tokens.count {
            var length = 1
            if tokens.count - i >= 2 {
                for size in stride(from: min(3, tokens.count - i), through: 2, by: -1) {
                    let slice = tokens[i..<(i + size)]
                    guard slice.allSatisfy({ $0.allSatisfy(\.isLetter) && !protected.contains($0) }) else { continue }
                    if compounds.contains(slice.joined()) { length = size; break }
                }
            }
            output.append(tokens[i..<(i + length)].joined())
            i += length
        }
        return output.joined(separator: " ")
    }
    init(products: [Product]) {
        self.products = products
        let identities = products.map { [$0.name, $0.brand, $0.manufacturer ?? ""].joined(separator: " ") }
        var vocabulary = Set(identities.flatMap { MealMatcher.normalize($0).split(separator: " ").map(String.init) }.filter { $0.count >= 4 && $0.allSatisfy(\.isLetter) })
        for product in products {
            let brand = MealMatcher.normalize(product.brand).split(separator: " ").map(String.init)
            if (2...3).contains(brand.count), brand.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isLetter) && !["без", "не", "или"].contains($0) }) {
                vocabulary.insert(brand.joined())
            }
        }
        compounds = vocabulary
        terms = identities.map { MealMatcher.searchWords(Self.compactWords($0, compounds: vocabulary)) }
        var counts: [String: Int] = [:]
        for words in terms { for word in words { counts[word, default: 0] += 1 } }
        frequencies = counts
        averageLength = max(1, Double(terms.reduce(0) { $0 + $1.count }) / Double(max(1, products.count)))
    }
    func rank(_ phrase: String, history: [MatchHistory], now: Date = Date(), restrictingTo allowed: Set<String>? = nil) -> [ProductCandidate] {
        let clean = MealMatcher.searchPhrase(Self.compactWords(phrase, compounds: compounds)), query = MealMatcher.searchWords(clean)
        guard !query.isEmpty else { return [] }
        let reference = MealMatcher.normalize(phrase).range(of: #"\b(который|которую|купил|купила|вчера|тот|та)\b"#, options: .regularExpression) != nil
        let numeric = Set(clean.split(separator: " ").filter { $0.contains(where: \.isNumber) }.map(String.init))
        func weight(_ word: String) -> Double {
            log(1 + (Double(products.count - (frequencies[word] ?? 0)) + 0.5) / (Double(frequencies[word] ?? 0) + 0.5))
        }
        let weightSum = query.reduce(0) { $0 + weight($1) }
        return products.indices.compactMap { index in
            let product = products[index], words = terms[index], common = words.intersection(query)
            if let allowed, !allowed.contains(product.id) { return nil }
            guard !common.isEmpty else { return nil }
            let identity = Self.compactWords([product.name, product.brand, product.manufacturer ?? ""].joined(separator: " "), compounds: compounds)
            let numericMatch = numeric.isSubset(of: Set(identity.split(separator: " ").map(String.init)))
            let complete = query.isSubset(of: words) && numericMatch
            let exact = Self.compactWords(product.name, compounds: compounds) == clean || identity == clean
            let equivalent = words == query && numericMatch
            let coverage = common.reduce(0) { $0 + weight($1) } / max(weightSum, 0.001)
            let bm25 = common.reduce(0.0) { sum, word in
                sum + weight(word) * 2.2 / (1 + 1.2 * (0.25 + 0.75 * Double(words.count) / averageLength))
            }
            var score = coverage * 55 + min(10, bm25)
            if complete { score = 85 - min(20, Double(words.subtracting(query).count) * 8) }
            if equivalent { score = 95 }
            if exact { score = 110 }
            if !numericMatch { score -= 25 }
            // History cannot repair absent explicit words or attributes.
            let remembered = history.filter { $0.product.id == product.id && $0.phrase == MealMatcher.normalize(phrase) }.max { $0.lastUsed < $1.lastUsed }
            if complete, let remembered {
                score += min(8, Double(remembered.count)) * exp(-max(0, now.timeIntervalSince(remembered.lastUsed)) / (30 * 86400))
            }
            let missing = query.subtracting(words).sorted().joined(separator: ", ")
            let reason = !numericMatch ? "Отличаются числовые признаки" : !complete ? "Не совпало: " + missing : reference ? "Нужно уточнить, какой именно продукт" : exact || equivalent ? "Совпадает название" : "Уточните разновидность продукта"
            return ProductCandidate(product: product, score: score, reason: reason,
                automaticEligible: !reference && numericMatch && (exact || equivalent))
        }.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }
}

