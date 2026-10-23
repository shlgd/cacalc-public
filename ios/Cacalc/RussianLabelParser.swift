import Foundation

/// A small grammar for label dictation, not a general Russian language model.
enum RussianLabelParser {
    enum Field: String, CaseIterable, Sendable {
        case calories, protein, fat, carbs
        var title: String {
            switch self { case .calories: "Калории"; case .protein: "Белки"; case .fat: "Жиры"; case .carbs: "Углеводы" }
        }
        var path: WritableKeyPath<ProductCreationDraft, String> {
            switch self { case .calories: \.calories; case .protein: \.protein; case .fat: \.fat; case .carbs: \.carbs }
        }
    }
    struct Result: Sendable {
        var values: [Field: Decimal] = [:]
        var basis: Basis?
        var name: String?
        var explicitName = false
        var brand: String?
        var manufacturer: String?
        var unresolved: Set<Field> = []
        var notices: [String] = []

        func applying(to original: ProductCreationDraft) -> ProductCreationDraft {
            var draft = original
            draft.notices = notices
            if let name, !name.isEmpty, explicitName || original.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.name = name; draft.identitySource = nil
            }
            if let brand { draft.brand = brand; draft.identitySource = nil }
            if let manufacturer { draft.manufacturer = manufacturer }
            // A partial dictation must not reinterpret old grams as millilitres.
            if let basis, basis != original.basis,
               Field.allCases.contains(where: { !original[keyPath: $0.path].isEmpty && values[$0] == nil }) {
                draft.notices.insert("Изменилась основа. Уточните г/мл и продиктуйте все КБЖУ.", at: 0)
                return draft
            }
            if let basis { draft.basis = basis }
            for (field, value) in values { draft[keyPath: field.path] = Numbers.string(value) }
            if !unresolved.isEmpty {
                let names = Field.allCases.filter { unresolved.contains($0) }.map(\.title).joined(separator: ", ")
                draft.notices.append("Уточните: \(names). Эти поля не изменены.")
            }
            if values.isEmpty && notices.isEmpty && unresolved.isEmpty {
                draft.notices.append("Можно назвать показатель и число: «Белков пять запятая восемь».")
            }
            return draft
        }
    }
    private struct Token {
        var word: String
        var range: NSRange
    }
    private struct NumberMention {
        var range: Range<Int>
        var value: Decimal?
    }
    private struct Label { var index: Int; var field: Field }
    private struct Link { var label: Int; var number: Int; var cost: Double }
    private static let lexer = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?(?:[eE][+-]?\d+)?|[\p{L}]+|[^\s]"#)
    private static let aliases: [String: Field] = {
        var result: [String: Field] = [:]
        for (field, words) in [
            (Field.protein, "белок белка белки белков белку белке белками белках протеин протеина протеинов"),
            (.fat, "жир жира жиры жиров жиру жире жирами жирах жирность жирности"),
            (.carbs, "углевод углевода углеводы углеводов углеводам углеводами углеводах"),
            (.calories, "калории калорий калория калорию калориях калориям калорийность калорийности килокалорий килокалории килокалория килокалорию ккал")
        ] { for word in words.split(separator: " ") { result[String(word)] = field } }
        return result
    }()
    private static let grams = Set("г гр грамм грамма граммов грамму грамме граммами".split(separator: " ").map(String.init))
    private static let millilitres = Set("мл миллилитр миллилитра миллилитров миллилитре".split(separator: " ").map(String.init))
    private static let fillers = Set("а и тут там здесь у меня в этом продукте по это получается значит короче всего примерно сейчас посмотрю содержится содержание составляет будет есть вообще ну так да я сказал неправильно не ой нет точнее вернее исправь исправляю должно быть".split(separator: " ").map(String.init))
    private static let corrections = Set(["нет", "точнее", "вернее", "исправь", "исправляю", "неправильно"])
    private static let punctuation = Set([",", ".", ";", ":", "—", "–", "-", "(", ")"])
    private static let otherMeasures = Set("пачка пачки упаковка упаковки вес масса массой нетто объем цена стоимость рублей рубля штрихкод сахара сахар соль соли клетчатка клетчатки натрия натрий".split(separator: " ").map(String.init))

    static func parse(_ text: String) throws -> Result {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 6_000 else {
            throw FoodError.database("Продиктуйте один продукт, не длиннее 6000 символов.")
        }
        let source = text as NSString
        let tokens = lexer.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            Token(word: source.substring(with: $0.range).lowercased().replacingOccurrences(of: "ё", with: "е"), range: $0.range)
        }
        let words = tokens.map(\.word)
        let labels = tokens.indices.compactMap { i in aliases[words[i]].map { Label(index: i, field: $0) } }
        var numbers: [NumberMention] = []
        var cursor = 0
        while cursor < words.count {
            if let number = RussianLabelNumber.read(words, at: cursor) {
                let leadingDot = cursor > 0 && words[cursor - 1] == "." && NSMaxRange(tokens[cursor - 1].range) == tokens[cursor].range.location
                let trailingDot = number.end + 1 < words.count && words[number.end] == "." &&
                    NSMaxRange(tokens[number.end - 1].range) == tokens[number.end].range.location &&
                    NSMaxRange(tokens[number.end].range) == tokens[number.end + 1].range.location && words[number.end + 1].first?.isNumber == true
                numbers.append(NumberMention(range: cursor..<number.end, value: leadingDot || trailingDot ? nil : number.value)); cursor = number.end
            } else { cursor += 1 }
        }
        var result = Result()
        var excluded = Set<Int>()
        var bases = Set<Basis>()
        var basisStarts: [Int] = []
        var portion = false
        for i in words.indices where words[i] == "на" {
            if i + 1 < words.count && words[i + 1].hasPrefix("порци") { portion = true }
            guard let number = numbers.first(where: { $0.range.lowerBound == i + 1 }), number.range.upperBound < words.count else { continue }
            let unit = words[number.range.upperBound]
            guard grams.contains(unit) || millilitres.contains(unit) else { continue }
            excluded.formUnion(i...number.range.upperBound); basisStarts.append(i)
            if number.value == 100 {
                let tail = words[(number.range.upperBound + 1)..<min(words.count, number.range.upperBound + 5)]
                if !tail.contains("нет") && !tail.contains("не") { bases.insert(grams.contains(unit) ? .g : .ml) }
            } else { portion = true }
        }
        if bases.count == 1 { result.basis = bases.first }
        let identity = identityFields(source: source, tokens: tokens, labels: labels, basisStarts: basisStarts)
        result.name = identity.name; result.brand = identity.brand; result.manufacturer = identity.manufacturer
        result.explicitName = words.contains("название") || words.contains("называется")
        if portion || bases.count > 1 || identity.multiple {
            result.basis = nil
            result.notices = [identity.multiple ? "Продиктуйте одну карточку за раз. КБЖУ не изменены." : "Уточните значения на 100 г или 100 мл. КБЖУ не изменены."]
            return result
        }
        let numericPositions = Set(numbers.flatMap { Array($0.range) })
        for number in numbers {
            for i in (max(0, number.range.lowerBound - 4)..<number.range.lowerBound).reversed() {
                if numericPositions.contains(i) || aliases[words[i]] != nil || [".", ",", ";"].contains(words[i]) { break }
                if otherMeasures.contains(words[i]) { excluded.formUnion(number.range); break }
            }
        }
        let activeNumbers = numbers.indices.filter { excluded.isDisjoint(with: numbers[$0].range) }
        let forward = (labels.first?.index ?? 0) < (activeNumbers.first.map { numbers[$0].range.lowerBound } ?? 0)
        var links: [Link] = []
        for (li, label) in labels.enumerated() {
            for ni in activeNumbers {
                let number = numbers[ni]
                let after = number.range.lowerBound > label.index
                let gap = after ? (label.index + 1)..<number.range.lowerBound : number.range.upperBound..<label.index
                guard gap.count <= 14, excluded.isDisjoint(with: gap), gap.allSatisfy({
                    fillers.contains(words[$0]) || grams.contains(words[$0]) || punctuation.contains(words[$0])
                }) else { continue }
                let lower = min(label.index, number.range.lowerBound)
                let upper = max(label.index + 1, number.range.upperBound)
                let context = Array(words[lower..<upper]) + (number.range.upperBound < words.count ? [words[number.range.upperBound]] : [])
                if number.range.upperBound < words.count && ["до", "или", "±"].contains(words[number.range.upperBound]) { continue }
                // Neither percentages, mg, prices nor kJ become label grams/kcal.
                guard !context.contains(where: { ["%", "процент", "процентов", "процента", "кдж", "килоджоулей", "килоджоуля", "мг", "миллиграмм", "миллиграмма", "миллиграммов", "рублей", "рубля"].contains($0) }),
                      !(label.field == .fat && context.contains(where: { $0.hasPrefix("сух") })) else { continue }
                if context.contains(where: { millilitres.contains($0) }) { continue }
                if label.field == .calories && context.contains(where: { grams.contains($0) }) { continue }
                let cost = gap.reduce(0.0) { $0 + (words[$1] == "." ? 12 : ([",", ";"].contains(words[$1]) ? 3 : 0.1)) } + (after == forward ? 0 : 0.4)
                links.append(Link(label: li, number: ni, cost: cost))
            }
        }
        links.sort { $0.cost == $1.cost ? ($0.label == $1.label ? $0.number < $1.number : $0.label < $1.label) : $0.cost < $1.cost }
        var assignments: [Int: Int] = [:], used = Set<Int>()
        for link in links where assignments[link.label] == nil && !used.contains(link.number) {
            assignments[link.label] = link.number; used.insert(link.number)
        }
        // A correction without repeating the field refers only to the adjacent assigned value.
        var replacements: [Int: Int] = [:]
        var conflicts = Set<Int>()
        for ni in activeNumbers where !used.contains(ni) {
            let number = numbers[ni]
            guard let previous = assignments.filter({ numbers[replacements[$0.key] ?? $0.value].range.upperBound <= number.range.lowerBound })
                .max(by: { numbers[replacements[$0.key] ?? $0.value].range.upperBound < numbers[replacements[$1.key] ?? $1.value].range.upperBound }) else { continue }
            let old = numbers[replacements[previous.key] ?? previous.value]
            let gap = old.range.upperBound..<number.range.lowerBound
            guard gap.count <= 12, excluded.isDisjoint(with: gap), gap.allSatisfy({ fillers.contains(words[$0]) || grams.contains(words[$0]) || punctuation.contains(words[$0]) }) else { continue }
            let label = labels[previous.key]
            let wasNegated = words[min(label.index, old.range.lowerBound)..<old.range.upperBound].contains("не")
            if gap.contains(where: { corrections.contains(words[$0]) }) || (wasNegated && gap.contains(where: { words[$0] == "а" })) {
                replacements[previous.key] = ni
            } else { conflicts.insert(previous.key) }
        }
        var lastEnd: [Field: Int] = [:]
        for (li, ni) in assignments.sorted(by: { labels[$0.key].index < labels[$1.key].index }) {
            let label = labels[li], number = numbers[replacements[li] ?? ni]
            let negated = words[min(label.index, number.range.lowerBound)..<number.range.upperBound].contains("не") ||
                (number.range.lowerBound > 0 && words[number.range.lowerBound - 1] == "не")
            if negated && replacements[li] == nil { conflicts.insert(li) }
            let nextLabel = labels.first(where: { $0.index > max(label.index, number.range.upperBound - 1) })
            if let nextLabel, nextLabel.field != label.field {
                let tail = words[number.range.upperBound..<nextLabel.index]
                if tail.contains("нет") && tail.contains("это") { continue }
            }
            guard !conflicts.contains(li), let value = number.value else {
                result.values[label.field] = nil; result.unresolved.insert(label.field); continue
            }
            let start = lastEnd[label.field] ?? min(label.index, number.range.lowerBound)
            let hasCorrection = words[start..<max(start, number.range.lowerBound)].contains(where: { corrections.contains($0) })
            if let previous = result.values[label.field], previous != value && !hasCorrection {
                result.values[label.field] = nil; result.unresolved.insert(label.field)
            } else if !result.unresolved.contains(label.field) || hasCorrection {
                result.values[label.field] = value; result.unresolved.remove(label.field)
            }
            lastEnd[label.field] = max(label.index + 1, number.range.upperBound)
        }
        for label in labels where result.values[label.field] == nil { result.unresolved.insert(label.field) }
        return result
    }

    private static func identityFields(source: NSString, tokens: [Token], labels: [Label], basisStarts: [Int]) -> (name: String?, brand: String?, manufacturer: String?, multiple: Bool) {
        let markers = ["название", "называется", "марка", "бренд", "производитель", "изготовитель"]
        let stops = Set(labels.map(\.index) + basisStarts + tokens.indices.filter { markers.contains(tokens[$0].word) })
        func phrase(from start: Int) -> String? {
            var end = start
            while end < tokens.count && !stops.contains(end) && ![".", ",", ";", ":"].contains(tokens[end].word) { end += 1 }
            guard end > start else { return nil }
            let range = NSRange(location: tokens[start].range.location, length: NSMaxRange(tokens[end - 1].range) - tokens[start].range.location)
            let value = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 200, !value.lowercased().contains("не помню"), !value.lowercased().contains("не знаю") else { return nil }
            return value
        }
        var name: String?, brand: String?, manufacturer: String?
        var names = 0
        for i in tokens.indices {
            let word = tokens[i].word
            guard markers.contains(word) else { continue }
            var start = i + 1
            if start < tokens.count && tokens[start].word == ":" { start += 1 }
            let value = phrase(from: start)
            switch word {
            case "название", "называется": name = value; names += 1
            case "марка", "бренд": brand = value
            default: manufacturer = value
            }
        }
        if name == nil {
            var start = 0
            while start < tokens.count && (fillers.contains(tokens[start].word) || tokens[start].word == ",") { start += 1 }
            if start < tokens.count && !stops.contains(start) && !["на", "купил", "купила", "пачка", "вес", "цена"].contains(tokens[start].word),
               RussianLabelNumber.read(tokens.map(\.word), at: start) == nil { name = phrase(from: start) }
        }
        let normalized = tokens.map(\.word).joined(separator: " ")
        let multiple = names > 1 || ["второй продукт", "следующий продукт", "другой продукт", "еще один продукт"].contains(where: normalized.contains)
        return (name, brand, manufacturer, multiple)
    }
}

/// Russian cardinal/decimal grammar. Values are built as decimal strings, never Double.
enum RussianLabelNumber {
    private static let integers: [String: Int] = {
        let groups: [(Int, String)] = [
            (0, "ноль нуль нуля нулю нулем"), (1, "один одна одно одну одного одной одному"),
            (2, "два две двух двум"), (3, "три трех трем"), (4, "четыре четырех четырем"),
            (5, "пять пяти"), (6, "шесть шести"), (7, "семь семи"), (8, "восемь восьми"), (9, "девять девяти"),
            (10, "десять десяти"), (11, "одиннадцать одиннадцати"), (12, "двенадцать двенадцати"),
            (13, "тринадцать тринадцати"), (14, "четырнадцать четырнадцати"), (15, "пятнадцать пятнадцати"),
            (16, "шестнадцать шестнадцати"), (17, "семнадцать семнадцати"), (18, "восемнадцать восемнадцати"), (19, "девятнадцать девятнадцати"),
            (20, "двадцать двадцати"), (30, "тридцать тридцати"), (40, "сорок сорока"), (50, "пятьдесят пятидесяти"),
            (60, "шестьдесят шестидесяти"), (70, "семьдесят семидесяти"), (80, "восемьдесят восьмидесяти"), (90, "девяносто девяноста"),
            (100, "сто ста"), (200, "двести двухсот"), (300, "триста трехсот"), (400, "четыреста четырехсот"),
            (500, "пятьсот пятисот"), (600, "шестьсот шестисот"), (700, "семьсот семисот"), (800, "восемьсот восьмисот"), (900, "девятьсот девятисот")
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { value, words in words.split(separator: " ").map { (String($0), value) } })
    }()
    private static let scales = ["тысяча": 1000, "тысячи": 1000, "тысяч": 1000, "миллион": 1_000_000, "миллиона": 1_000_000, "миллионов": 1_000_000]
    private static let denominators = ["десятая": 1, "десятых": 1, "десятой": 1, "сотая": 2, "сотых": 2, "сотой": 2, "тысячная": 3, "тысячных": 3, "тысячной": 3]
    private static let markers = Set(["запятая", "запятой", "точка", "точкой", "целая", "целых", "целое", "целую", "и"])
    private static let halves = ["полграмма": "0.5", "полграмм": "0.5", "половина": "0.5", "полтора": "1.5", "полторы": "1.5"]
    private static func numeric(_ word: String) -> Bool {
        integers[word] != nil || scales[word] != nil || halves[word] != nil || word.first?.isNumber == true
    }
    static func read(_ words: [String], at start: Int) -> (end: Int, value: Decimal?)? {
        guard start < words.count, numeric(words[start]) else { return nil }
        var end = start + 1
        while end < words.count {
            let word = words[end]
            if numeric(word) || denominators[word] != nil { end += 1 }
            else if markers.contains(word), end + 1 < words.count,
                    numeric(words[end + 1]) || ([",", "."].contains(words[end + 1]) && end + 2 < words.count && numeric(words[end + 2])) { end += 1 }
            else if [",", "."].contains(word), markers.contains(words[end - 1]) { end += 1 }
            else if word == "с", end + 1 < words.count, words[end + 1] == "половиной" { end += 2 }
            else { break }
        }
        let negative = start > 0 && ["минус", "-", "−"].contains(words[start - 1])
        let malformed = start > 0 && ["<", ">"].contains(words[start - 1])
        let components = Array(words[start..<end]).filter { ![",", "."].contains($0) }
        return (end, negative || malformed ? nil : value(components))
    }
    private static func value(_ words: [String]) -> Decimal? {
        if words.count == 1 { return Numbers.source(halves[words[0]] ?? words[0]) ?? integers[words[0]].map { Decimal($0) } ?? scales[words[0]].map { Decimal($0) } }
        if words.suffix(2) == ["с", "половиной"], let whole = integer(Array(words.dropLast(2))) { return Numbers.source("\(whole).5") }
        let denominator = words.last.flatMap { denominators[$0] }
        let body = denominator == nil ? words : Array(words.dropLast())
        if let marker = body.firstIndex(where: { markers.contains($0) }) {
            guard let whole = integer(Array(body[..<marker])) else { return nil }
            let fraction = Array(body[(marker + 1)...])
            if let denominator, let part = integer(fraction) {
                let digits = String(part)
                guard digits.count <= denominator else { return nil }
                return Numbers.source("\(whole)." + String(repeating: "0", count: denominator - digits.count) + digits)
            }
            guard let digits = digits(fraction) else { return nil }
            return Numbers.source("\(whole).\(digits)")
        }
        if let denominator, let part = integer(body) {
            let digits = String(part)
            guard digits.count <= denominator else { return nil }
            return Numbers.source("0." + String(repeating: "0", count: denominator - digits.count) + digits)
        }
        if let whole = integer(words) { return Decimal(whole) }
        // Nutrition shorthand: one cardinal followed by fractional digits/cardinals.
        let groups = groups(words)
        guard groups.count >= 2, groups.count <= 5, groups.joined(separator: "").count <= 19 else { return nil }
        return Numbers.source(groups[0] + "." + groups.dropFirst().joined())
    }
    private static func digits(_ words: [String]) -> String? {
        let groups = groups(words)
        guard !groups.isEmpty, groups.count <= 6 else { return nil }
        return groups.joined()
    }
    private static func integer(_ words: [String]) -> Int? {
        if let scale = words.firstIndex(where: { scales[$0] != nil }) {
            guard let factor = scales[words[scale]],
                  let before = scale == 0 ? 1 : integer(Array(words[..<scale])),
                  let after = scale == words.count - 1 ? 0 : integer(Array(words[(scale + 1)...])),
                  before > 0, before <= 1_000_000 / factor, after < factor else { return nil }
            let value = before * factor + after
            return value <= 1_000_000 ? value : nil
        }
        let groups = groups(words)
        return groups.count == 1 ? Int(groups[0]) : nil
    }
    private static func groups(_ words: [String]) -> [String] {
        var result: [String] = [], value = 0, ceiling = 1000
        func finish() {
            if ceiling != 1000 { result.append(String(value)); value = 0; ceiling = 1000 }
        }
        for word in words {
            if let literal = Int(word), literal >= 0, literal <= 1_000_000 { finish(); result.append(word); continue }
            guard let number = integers[word] else { return [] }
            if number >= ceiling || ceiling == 0 { finish() }
            value += number
            ceiling = number >= 100 ? 100 : (number >= 20 ? 10 : 0)
        }
        finish()
        return result
    }
}
