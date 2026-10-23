import Foundation

@main struct LabelParserBench {
    struct Corpus: Decodable {
        struct Case: Decodable { var id: String; var text: String; var expected: [String: String?] }
        var cases: [Case]
    }
    static func main() throws {
        var count = 0, failures = 0, timings: [Double] = []
        for file in CommandLine.arguments.dropFirst() {
            let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            for item in corpus.cases {
                let start = ContinuousClock.now
                let result = try RussianLabelParser.parse(item.text)
                timings.append(seconds(start.duration(to: .now)) * 1000)
                var actual = Dictionary(uniqueKeysWithValues: RussianLabelParser.Field.allCases.map { ($0.rawValue, result.values[$0].map(Numbers.string)) })
                actual["basis"] = .some(result.basis?.rawValue)
                actual["name"] = .some(result.name); actual["brand"] = .some(result.brand)
                count += 1
                let errors = item.expected.compactMap { key, expected -> String? in
                    let value = actual[key] ?? nil
                    return value == expected ? nil : "\(key): \(value ?? "null") != \(expected ?? "null")"
                }
                if !errors.isEmpty { failures += 1; print("FAIL \(item.id): " + errors.joined(separator: "; ")) }
            }
        }
        let nutrients: [(RussianLabelParser.Field, String, String)] = [(.protein, "белков", "5.8"), (.fat, "жиров", "0,05"), (.carbs, "углеводов", "1.42"), (.calories, "калорий", "48")]
        for order in permutations(nutrients) {
            for reverse in [false, true] {
                for separator in [" ", ", ", ". "] {
                    let text = order.map { reverse ? "\($0.2) \($0.1)" : "\($0.1) \($0.2)" }.joined(separator: separator)
                    let result = try RussianLabelParser.parse(text)
                    count += 1
                    if nutrients.contains(where: { result.values[$0.0] != Numbers.source($0.2) }) {
                        failures += 1; print("FAIL permutation: \(text) => \(result.values)")
                    }
                }
            }
        }
        let sorted = timings.sorted()
        print("CASES=\(count) PASSED=\(count - failures) FAILED=\(failures)")
        if !sorted.isEmpty { print("MAC_PARSE_MS median=\(sorted[sorted.count / 2]) max=\(sorted.last!) (ASR and disk excluded)") }
        if failures > 0 { exit(1) }
    }
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    static func permutations<T>(_ values: [T]) -> [[T]] {
        if values.isEmpty { return [[]] }
        return values.indices.flatMap { index in permutations(Array(values[..<index]) + values[(index + 1)...]).map { [values[index]] + $0 } }
    }
}
