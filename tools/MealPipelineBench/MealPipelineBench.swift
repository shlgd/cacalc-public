import Foundation
import SwiftData
import AVFoundation

@main struct MealPipelineBench {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { FileHandle.standardError.write(Data(("CHECK FAILED: " + message + "\n").utf8)); fatalError(message) }
    }
    @MainActor static func wait(_ session: MealSession) async throws {
        for _ in 0..<500 {
            if !session.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Pipeline timed out")
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--performance") { try await checkAuditPerformance(); return }
        // Synthetic catalog: ingredients are also independently known foods.
        let compoundProducts = [
            Product(id: "synthetic-ham", name: "Ветчина из филе индейки", brand: "Индилайт", basis: .g, source: "synthetic"),
            Product(id: "synthetic-fillet", name: "Филе индейки", brand: "", basis: .g, source: "synthetic"),
            Product(id: "synthetic-turkey", name: "Индейка", brand: "", basis: .g, source: "synthetic"),
            Product(id: "synthetic-chicken", name: "Курица", brand: "", basis: .g, source: "synthetic"),
            Product(id: "synthetic-cutlets", name: "Котлеты", brand: "", basis: .g, source: "synthetic"),
            Product(id: "synthetic-milk", name: "Молоко", brand: "", basis: .g, source: "synthetic"),
            Product(id: "synthetic-rice", name: "Рис", brand: "", basis: .g, source: "synthetic"),
            Product(id: "synthetic-egg", name: "Вареное яйцо", brand: "", basis: .g, source: "synthetic"),
            Product(id: "synthetic-flakes", name: "Кукурузные хлопья", brand: "Любятово", basis: .g, source: "synthetic"),
            Product(id: "synthetic-branded-name", name: "Любятово кукурузные хлопья", brand: "", basis: .g, source: "synthetic"),
            Product(id: "synthetic-juice", name: "Сок яблоко огурец сельдерей", brand: "", basis: .g, source: "synthetic"),
            Product(id: "synthetic-apple", name: "Яблоко", brand: "", basis: .g, source: "synthetic"),
            Product(id: "synthetic-cucumber", name: "Огурец", brand: "", basis: .g, source: "synthetic")
        ]
        let compoundLexicon = MealPairParser.Lexicon(index: SearchIndex(products: compoundProducts))
        let hamPhrase = "Ветчина из филе индейки Индилайт пятьдесят грамм."
        for final in [false, true] {
            let ham = MealPairParser.analyze(hamPhrase, lexicon: compoundLexicon, final: final).result
            require(ham.rows.count == 1 && ham.rows[0].food == "ветчина из филе индейки индилайт" &&
                    ham.rows[0].amount == 50 && ham.rows[0].unit == .g && ham.pending.isEmpty,
                    "ingredient name and brand complete one food during preview and at pause")
        }
        for (phrase, name, amount) in [
            ("50 грамм ветчины из филе индейки Индилайт", "ветчины из филе индейки индилайт", Decimal(50)),
            ("ветчина из филе индейки новая марка 50 г", "ветчина из филе индейки новая марка", Decimal(50)),
            ("котлеты из курицы мастер 80 г", "котлеты из курицы мастер", Decimal(80)),
            ("филе индейки с соусом 120 г", "филе индейки с соусом", Decimal(120)),
            ("филе индейки без соуса 120 г", "филе индейки без соуса", Decimal(120)),
            ("рис вареный 150 г", "рис вареный", Decimal(150)),
            ("150 г рис вареный", "рис вареный", Decimal(150)),
            ("кукурузные хлопья любятово 100 г", "кукурузные хлопья любятово", Decimal(100)),
            ("100 г кукурузные хлопья любятово", "кукурузные хлопья любятово", Decimal(100))
        ] {
            let result = MealPairParser.analyze(phrase, lexicon: compoundLexicon, final: true).result
            require(result.rows.count == 1 && result.rows[0].food == name && result.rows[0].amount == amount &&
                    result.pending.isEmpty, "ingredient modifiers keep one contiguous food: " + phrase)
        }
        for phrase in ["ветчина индейка 50 г", "ветчина индейка из курицы 50 г", "из филе индейки 50 г", "ветчина из 50 г"] {
            let result = MealPairParser.analyze(phrase, lexicon: compoundLexicon, final: true).result
            require(result.rows.isEmpty && !result.pending.isEmpty, "missing or multiple main foods stay pending: " + phrase)
        }
        for command in ["дальше", "далее"] {
            let result = MealPairParser.analyze(hamPhrase + " " + command + " молоко 100 г", lexicon: compoundLexicon, final: true).result
            require(result.rows.map(\.amount) == [50, 100] && result.rows[1].food == "молоко" && result.pending.isEmpty,
                    "explicit next command separates complete ingredient name: " + command)
        }
        for final in [false, true] {
            for repeated in ["50 грамм", "пятьдесят грамм пятьдесят граммов"] {
                let output = MealPairParser.analyze(hamPhrase + " " + repeated, lexicon: compoundLexicon, final: final)
                require(output.result.rows.map(\.amount) == [50] && output.result.pending.isEmpty &&
                        output.trace.decisions.contains(where: { $0.contains("repeated explicit quantity") }),
                        "repeated identical explicit weight cannot reopen completed ham")
            }
            let next = MealPairParser.analyze(hamPhrase + " 50 г далее молоко 100 г", lexicon: compoundLexicon, final: final).result
            require(next.rows.map(\.amount) == [50, 100] && next.rows[1].food == "молоко" && next.pending.isEmpty,
                    "repeated ham weight cannot block following food")
        }
        for phrase in [hamPhrase + " 100 грамм", hamPhrase + " 50 мл", "ветчина 1 штука 1 штука"] {
            let result = MealPairParser.analyze(phrase, lexicon: compoundLexicon, final: true).result
            require(result.rows.isEmpty && !result.pending.isEmpty,
                    "different weight/unit or piece count cannot be collapsed: " + phrase)
        }
        let bareRepeat = MealPairParser.analyze(hamPhrase + " пятьдесят", lexicon: compoundLexicon, final: true).result
        require(bareRepeat.rows.map(\.amount) == [50] && bareRepeat.pending == "пятьдесят",
                "bare trailing number stays unresolved without undoing the earlier explicit pair")
        let repeatedBeforeFood = MealPairParser.analyze("50 грамм 50 граммов ветчина из филе индейки Индилайт", lexicon: compoundLexicon, final: true).result
        require(repeatedBeforeFood.rows.isEmpty && !repeatedBeforeFood.pending.isEmpty,
                "unbound repeated weights before the name require clarification")
        let equalWeightTransition = MealPairParser.analyze("ветчина 50 грамм 50 грамм молоко 100 грамм рис", lexicon: compoundLexicon, final: true).result
        let expectedTransition: [(String, Decimal)] = [("ветчина", 50), ("молоко", 50), ("рис", 100)]
        require(equalWeightTransition.rows.count <= expectedTransition.count &&
                zip(equalWeightTransition.rows, expectedTransition).allSatisfy({ $0.food == $1.0 && $0.amount == $1.1 }),
                "equal weights between adjacent foods cannot steal the following food's quantity")
        let distinctFoodsSameWeight = MealPairParser.analyze("ветчина 50 грамм молоко 50 грамм", lexicon: compoundLexicon, final: true).result
        require(distinctFoodsSameWeight.rows.map(\.amount) == [50, 50] && distinctFoodsSameWeight.pending.isEmpty,
                "a food name between equal weights keeps both independent rows")
        for marker in ["еще", "плюс", "+"] {
            let additive = MealPairParser.analyze(hamPhrase + " " + marker + " 50 грамм", lexicon: compoundLexicon, final: true).result
            require(additive.rows.map(\.amount) == [50] && additive.pending == marker + " 50 грамм",
                    "explicit addition cannot become a repeated-weight confirmation")
            let reopened = MealPairParser.analyze(additive.pending, lexicon: compoundLexicon, final: true).result
            require(reopened.rows.isEmpty && reopened.pending == additive.pending,
                    "retained additive tail stays unresolved after another pause or reopen")
        }
        let separateIngredients = MealPairParser.analyze("73 грамма яблока огурец 91 грамм", lexicon: compoundLexicon, final: true).result
        require(separateIngredients.rows.map(\.amount) == [73, 91] &&
                separateIngredients.rows.map(\.food) == ["яблока", "огурец"] && separateIngredients.pending.isEmpty,
                "catalog juice ingredients cannot bind two separately weighed foods")
        for phrase in ["сок яблоко огурец сельдерей 100 г", "100 г сок яблоко огурец сельдерей"] {
            let result = MealPairParser.analyze(phrase, lexicon: compoundLexicon, final: true).result
            require(result.rows.count == 1 && result.rows[0].food == "сок яблоко огурец сельдерей" &&
                    result.rows[0].amount == 100 && result.pending.isEmpty, "full juice name stays intact: " + phrase)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--planner-snapshot"), CommandLine.arguments.count > index + 2 {
            try await checkPlannerSnapshot(source: URL(filePath: CommandLine.arguments[index + 1]),
                                           destination: URL(filePath: CommandLine.arguments[index + 2]))
        }
        try await checkVariantSelection()
        fflush(nil)
        try await checkAuditFixes()
        fflush(nil)
        try await checkAuditCachesAndWriter()
        fflush(nil)
        try await checkAuditInvalidation()
        fflush(nil)
        try await checkPreparedFood()
        fflush(nil)
        try await checkCombinations()
        fflush(nil)
        try await checkMealPlanning()
        fflush(nil)
        let shortSignal = Array(repeating: Float(0.02), count: 4_160)
        let paddedSignal = LiveASRInput.padded(shortSignal)
        require(paddedSignal.count == 4_800 && Array(paddedSignal.prefix(4_160)) == shortSignal,
                "260ms command preserves samples and reaches decoder minimum")
        require(paddedSignal.suffix(640).allSatisfy { $0 == 0 }, "padding adds silence only")
        require(LiveASRInput.padded([]).isEmpty, "empty audio stays empty")
        require(LiveASRInput.padded(paddedSignal) == paddedSignal, "valid input unchanged")
        let cereal = Product(id: "synthetic-cereal", name: "Кукурузные хлопья", brand: "Любятово", basis: .g, source: "synthetic")
        let alternativeCereal = Product(id: "synthetic-other-cereal", name: "Кукурузные хлопья", brand: "Любята", basis: .g, source: "synthetic")
        var identityMemory = LiveIdentityMemory()
        _ = identityMemory.resolve("кукурузные хлопья любятово", products: [cereal])
        require(identityMemory.resolve("кукурузные хлопья любят", products: [cereal]) == "кукурузные хлопья любятово", "retain known brand before weight")
        _ = identityMemory.resolve("кукурузные хлопья любятого", products: [cereal])
        require(identityMemory.resolve("кукурузные хлопья любят 120 грамм", products: [cereal]) == "кукурузные хлопья любятово 120 грамм", "earlier identity survives revised suffix until weight")
        require(identityMemory.resolve("кукурузные хлопья любята 120 грамм", products: [cereal, alternativeCereal]) == "кукурузные хлопья любята 120 грамм", "explicit other catalogue identity wins")
        _ = identityMemory.resolve("нет кукурузные хлопья любятово", products: [cereal])
        require(identityMemory.resolve("кукурузные хлопья любят 120 грамм", products: [cereal]) == "кукурузные хлопья любят 120 грамм", "correction resets evidence")
        _ = identityMemory.resolve("кукурузные хлопья любятово", products: [cereal])
        identityMemory.reset()
        require(identityMemory.resolve("кукурузные хлопья любят 120 грамм", products: [cereal]) == "кукурузные хлопья любят 120 грамм", "new phrase never inherits identity")
        let protein = Product(id: "synthetic-protein", name: "Протеин", brand: "Первый русский протеин", basis: .g, source: "synthetic")
        let proteinIndex = SearchIndex(products: [protein])
        require(MealMatcher.suggestion(proteinIndex.rank("протин первый русский протеин", history: []))?.id == protein.id, "one name typo with exact complete brand may select")
        require(MealMatcher.suggestion(proteinIndex.rank("протин", history: [])) == nil, "unbranded typo remains uncertain")
        let similarProtein = Product(id: "synthetic-protein2", name: "Протеин", brand: "Первый русский протеин", basis: .g, source: "synthetic")
        require(MealMatcher.suggestion(SearchIndex(products: [protein, similarProtein]).rank("протин первый русский протеин", history: [])) == nil, "same brand ambiguity still requires margin")

        // Synthetic products, with the cosine recorded in the real lentil incident.
        let puree = Product(id: "synthetic-puree", name: "Пюре из чечевицы", brand: "", basis: .g, source: "synthetic")
        let pureeIndex = SearchIndex(products: [puree])
        let cosine = [puree.id: 0.9125565802174549]
        for phrase in ["чечевичного пюре", "пюре чечевичное"] {
            let ranked = pureeIndex.rank(phrase, history: [], semantic: cosine)
            require(MealMatcher.suggestion(ranked)?.id == puree.id, "supported variant: " + phrase)
            require(ranked.first?.evidence?.selectionRule == "supported-name-variant", "explain variant selection")
        }
        require(MealMatcher.suggestion(pureeIndex.rank("чечевичного пюре", history: [])) == nil, "variant without semantic support stays uncertain")
        for phrase in ["пюре", "картофельное пюре", "чечевичное пюре с маслом"] {
            require(MealMatcher.suggestion(pureeIndex.rank(phrase, history: [], semantic: cosine)) == nil, "high cosine cannot override identity: " + phrase)
        }
        var duplicatePuree = puree; duplicatePuree.id = "synthetic-duplicate-puree"
        let duplicateRanking = SearchIndex(products: [puree, duplicatePuree]).rank("чечевичное пюре", history: [], semantic: [puree.id: 0.92, duplicatePuree.id: 0.91])
        require(MealMatcher.suggestion(duplicateRanking) == nil && MealMatcher.selectionReason(duplicateRanking) == "close-alternative", "similar batches need a choice")
        var richerPuree = puree; richerPuree.name = "Пюре из чечевицы с маслом"
        require(MealMatcher.suggestion(SearchIndex(products: [richerPuree]).rank("чечевичное пюре", history: [], semantic: cosine)) == nil, "omitted ingredient stays uncertain")
        var brandedPuree = puree; brandedPuree.brand = "Агроальянс"
        require(MealMatcher.suggestion(SearchIndex(products: [brandedPuree]).rank("чечевичное пюре", history: [], semantic: cosine)) == nil, "omitted brand stays uncertain")
        require(MealMatcher.suggestion(proteinIndex.rank("протин", history: [], semantic: [protein.id: 0.99])) == nil, "cosine cannot replace anchor")
        let knownVariant = Product(id: "synthetic-variant", name: "Чечевичный суп", brand: "", basis: .g, source: "synthetic")
        require(MealMatcher.suggestion(SearchIndex(products: [puree, knownVariant]).rank("чечевичное пюре", history: [], semantic: cosine)) == nil, "known word cannot be silently corrected")

        if let path = ProcessInfo.processInfo.environment["CACALC_PAIR_CASES"] {
            struct Expected: Codable { var food: String; var quantity: String; var unit: String }
            struct Case: Decodable { var category: String; var text: String; var rows: [Expected]; var pending: Bool }
            struct Suite: Decodable { var foods: [String]; var cases: [Case] }
            let suite = try JSONDecoder().decode(Suite.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            var products = suite.foods.enumerated().map { Product(id: "synthetic-\($0.offset)", name: $0.element, brand: "", basis: .g, source: "synthetic") }
            let replayDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("pair-replay-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: replayDirectory) }
            var replayIndex: SearchIndex?
            if let catalog = ProcessInfo.processInfo.environment["CACALC_PAIR_CATALOG"] {
                if catalog == "bundled" {
                    products = try await Catalog(url: URL(fileURLWithPath: "ios/Resources/catalog.sqlite")).browse()
                } else {
                    products = try JSONDecoder().decode([Product].self, from: Data(contentsOf: URL(fileURLWithPath: catalog)))
                }
            }
            // Optional private check reads an independent database copy through
            // the same product/prepared repositories used by the live session.
            if let snapshot = ProcessInfo.processInfo.environment["CACALC_PAIR_DIARY_SNAPSHOT"] {
                try FileManager.default.createDirectory(at: replayDirectory, withIntermediateDirectories: true)
                let copy = replayDirectory.appendingPathComponent("replay.store")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: snapshot), to: copy)
                let realCatalog = Catalog(url: URL(fileURLWithPath: "ios/Resources/catalog.sqlite"))
                let realStore = DiaryStore(container: try DiaryStore.makeContainer(url: copy), catalog: realCatalog)
                replayIndex = try await realStore.productRepository.searchIndex(realCatalog)
                products = replayIndex!.products
                let replay = MealSession(store: realStore)
                await replay.begin(day: realStore.today)
                let owner = replay.draft!.id
                replay.draft?.audioFile = "text-replay.wav"; replay.draft?.dictationID = UUID()
                try await replay.acceptLiveHypothesis("Ветчина из филе индейки Индилайт", owner: owner, file: "text-replay.wav")
                require(replay.draft!.rows.isEmpty, "real catalog keeps unfinished ham name without a made-up weight")
                try await replay.acceptLiveHypothesis(hamPhrase + " пятьдесят грамм", owner: owner, file: "text-replay.wav")
                require(replay.draft!.rows.count == 1 && replay.draft!.rows[0].amount == 50,
                        "current personal/prepared catalog accepts full ham preview")
                let rowID = replay.draft!.rows[0].id
                try await replay.acceptLiveHypothesis(hamPhrase + " 50 грамм 50 грамм", owner: owner, file: "text-replay.wav")
                require(replay.draft!.rows.count == 1 && replay.draft!.rows[0].id == rowID,
                        "real catalog keeps one row across successive repeated weights")
                try await replay.acceptLivePhrase(hamPhrase + " пятьдесят грамм", through: 16000, owner: owner, file: "text-replay.wav", boundary: true)
                await replay.waitForLiveMatching()
                require(replay.draft!.rows.count == 1 && replay.draft!.rows[0].id == rowID &&
                        replay.draft!.rows[0].product?.name == compoundProducts[0].name && replay.draft!.livePendingText == "",
                        "real personal card matches without pending speech or duplicate row")
                try await replay.flush()
                let reopened = MealSession(store: realStore)
                await reopened.resume(owner)
                require(reopened.draft!.rows[0].id == rowID && reopened.draft!.rows[0].amount == 50,
                        "personal database copy persists and reloads completed ham")
                try await reopened.acceptLivePhrase("Далее молоко 100 грамм", through: 32000, owner: owner, file: "text-replay.wav", boundary: true)
                await reopened.waitForLiveMatching()
                require(reopened.draft!.rows.map(\.amount) == [50, 100] && reopened.draft!.rows[0].id == rowID &&
                        reopened.draft!.rows[1].food == "молоко" && reopened.draft!.livePendingText == "",
                        "personal database copy separates following milk from completed ham")
                if let export = ProcessInfo.processInfo.environment["CACALC_PAIR_CATALOG_EXPORT"] {
                    try JSONEncoder().encode(products).write(to: URL(fileURLWithPath: export))
                }
                print("PASS: private diary copy, actual product/prepared index, ham preview/pause/matching/reopen/next food; \(products.count) products")
            }
            let lexicon = MealPairParser.Lexicon(index: replayIndex ?? SearchIndex(products: products))
            var failures: [[String: String]] = []
            var counts: [String: Int] = [:], passed: [String: Int] = [:]
            var durations: [Double] = []
            for test in suite.cases {
                let started = Date()
                let output = MealPairParser.analyze(test.text, lexicon: lexicon, final: true)
                durations.append(Date().timeIntervalSince(started) * 1000)
                let actual = output.result.rows.map { Expected(food: $0.food, quantity: Numbers.string($0.amount ?? -1), unit: $0.unit?.rawValue ?? "") }
                counts[test.category, default: 0] += 1
                let actualData = try JSONEncoder().encode(actual)
                let correct = actual.count == test.rows.count && zip(actual, test.rows).allSatisfy { a,b in
                    a.food == b.food && Decimal(string: a.quantity) == Decimal(string: b.quantity) && a.unit == b.unit
                } && (!output.result.pending.isEmpty == test.pending)
                if correct { passed[test.category, default: 0] += 1 }
                else { failures.append(["category": test.category, "text": test.text,
                    "actual": String(decoding: actualData, as: UTF8.self), "pending": output.result.pending,
                    "trace": String(decoding: try JSONEncoder().encode(output.trace), as: UTF8.self)]) }
            }
            durations.sort()
            let report: [String: Any] = ["counts": counts, "passed": passed, "failures": failures,
                "p50ms": durations[durations.count / 2], "p95ms": durations[Int(Double(durations.count) * 0.95)],
                "maxMs": durations.last ?? 0]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            if let destination = ProcessInfo.processInfo.environment["CACALC_PAIR_REPORT"] { try data.write(to: URL(fileURLWithPath: destination)) }
            print("Pair grammar: \(passed) of \(counts), failures \(failures.count), p95 \(durations[Int(Double(durations.count) * 0.95)]) ms")
            if ProcessInfo.processInfo.environment["CACALC_PAIR_INCLUDE_PIPELINE"] != "1" { return }
        }
        if let path = ProcessInfo.processInfo.environment["CACALC_ENDPOINT_REPLAY_WAV"] {
            let window = try LiveWave.read(URL(fileURLWithPath: path), from: 0, finalized: true, limit: Int.max)
            var detector = LiveMealEndpoint()
            var boundaries: [Int] = []
            while let range = detector.next(window.samples, finished: false) {
                let quiet = window.samples[(range.upperBound - 19_200)..<range.upperBound]
                for start in stride(from: quiet.startIndex, to: quiet.endIndex, by: 320) {
                    let frame = quiet[start..<min(start + 320, quiet.endIndex)]
                    let rms = sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count))
                    require(rms <= 0.008, "real audio is never cut during sound")
                }
                boundaries.append(range.upperBound)
            }
            if let tail = detector.next(window.samples, finished: true) { boundaries.append(tail.upperBound) }
            print("Endpoint replay: \(window.totalSamples) samples; quiet/Stop boundaries \(boundaries)")
        }
        // Optional private replay uses saved model scores, never loads a model or network.
        if let path = ProcessInfo.processInfo.environment["CACALC_SEARCH_REPLAY_JSON"] {
            struct Replay: Decodable { let products: [Product]; let query: String; let semantic: [String: Double]; let expectedID: String }
            let replay = try JSONDecoder().decode(Replay.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let ranked = SearchIndex(products: replay.products).rank(replay.query, history: [], semantic: replay.semantic)
            print("Private replay: expected rank \(ranked.firstIndex(where: { $0.id == replay.expectedID }).map { $0 + 1 } ?? 0) of \(ranked.count); score \(ranked.first(where: { $0.id == replay.expectedID })?.score ?? 0)")
        }
        for phrase in ["Yeah.", "YEAH!", "Thank you.", "Thank you!", "I'm not sure.", "I’m not sure"] {
            require(MealSpeechPhraseFilter.rejectedPhrase(phrase) != nil, "observed standalone noise phrase rejected: " + phrase)
        }
        for phrase in ["100", "сто грамм", "Thank you молоко 200 грамм", "Yeah протеин 30 грамм", "MyProtein 30 грамм", "I'm not sure 100", "молоко", "стоп"] {
            require(MealSpeechPhraseFilter.rejectedPhrase(phrase) == nil, "names, numbers, mixed speech and commands preserved: " + phrase)
        }
        let filtered = FoodWordFilter.apply("ну блять давай добавим творог без сахара")
        require(filtered.text == "творог без сахара", "conversation filtered after ASR")
        require(filtered.removed.map(\.word) == ["ну", "блять", "давай", "добавим"], "filter explains each removal")
        require(MealMatcher.searchPhrase("Мякоть авокадо без сахара 5%") == "мякоть авокадо без сахара 5%", "meaningful attributes retained")
        require(MealMatcher.searchWords("ну блять и добавляю").isEmpty, "noise never searches for products")
        require(FoodWordFilter.apply("вареный сухой жареный неизвестнаямарка").text == "вареный сухой жареный неизвестнаямарка", "descriptors and unknown words retained")
        require(LiveMealParser.parse("ну давай добавим банан сто двадцать грамм").rows.first?.food == "банан", "noise removed from food name")
        require(LiveMealParser.parse("я добавил сто двадцать грамм банана").rows.first?.amount == 120, "noise before weight-first phrase")
        require(LiveMealParser.parse("ну блять двести грамм").rows.isEmpty, "noise plus weight never creates food")
        require(LiveMealParser.parse("не банан а яблоко 200 грамм").rows.isEmpty, "negation not discarded into confident food")
        require(LiveMealParser.parse("творог без сахара 150 грамм").rows.first?.food == "творог без сахара", "without remains product attribute")
        let spokenFat = LiveMealParser.parse("ну давай добавим творог пять процентов двести грамм")
        require(spokenFat.rows.first?.food == "творог 5%" && spokenFat.rows.first?.amount == 200, "spoken percentage stays identity while mass is separated")
        let agro = Product(id: "synthetic-agro", name: "Гречка", brand: "Агроальянс", basis: .g, source: "synthetic-test")
        let otherAgro = Product(id: "synthetic-other", name: "Гречка", brand: "Другая марка", basis: .g, source: "synthetic-test")
        let agroQuery = LiveMealParser.parse("Гречка «Агро Альянс» — 150 грамм!")
        require(agroQuery.rows.first?.food == "гречка агро альянс" && agroQuery.rows.first?.amount == 150, "quotes and dash stripped without losing food or weight")
        require(MealMatcher.suggestion(MealMatcher.rank(agroQuery.rows[0].food, products: [otherAgro, agro], history: []))?.id == agro.id, "split speech brand matches joined catalog brand")
        let spacedBrand = Product(id: "synthetic-spaced", name: "Гречка", brand: "Агро Альянс", basis: .g, source: "synthetic-test")
        require(MealMatcher.suggestion(MealMatcher.rank("гречка агроальянс", products: [otherAgro, spacedBrand], history: []))?.id == spacedBrand.id, "joined speech brand matches spaced catalog brand")
        require(LiveMealParser.preview("грамм").rows.isEmpty, "late gram token is not next food")
        require(LiveMealParser.parse("грамм огурец 120 грамм").rows.first?.food == "огурец", "late gram before next product ignored")
        require(LiveMealParser.preview("— « » / • ...").rows.isEmpty, "punctuation-only input never creates row")
        require(LiveMealParser.parse("гречка -150 грамм").rows.isEmpty, "negative quantity never silently becomes positive")
        require(LiveMealParser.parse("гречка Агро-Альянс 12,5 грамма").rows.first?.amount == Decimal(string: "12.5"), "brand hyphen does not block decimal weight")
        let rawChicken = Product(id: "raw-test", name: "Куриная грудка сырая", brand: "", basis: .g, source: "synthetic-test")
        let friedChicken = Product(id: "fried-test", name: "Куриная грудка жареная", brand: "", basis: .g, source: "synthetic-test")
        let chickenIndex = SearchIndex(products: [rawChicken, friedChicken])
        let chickenMatches = chickenIndex.rank("куриная грудка жареная", history: [], semantic: [rawChicken.id: 0.99])
        require(chickenMatches.first?.id == friedChicken.id, "explicit preparation beats semantic similarity")
        require(chickenMatches.first(where: { $0.id == rawChicken.id })?.evidence?.conflicts.isEmpty == false, "preparation conflict explained")
        require(MealMatcher.suggestion(chickenIndex.rank("куриная грудка", history: [])) == nil, "unspecified preparation needs review")
        let typoMatches = SearchIndex(products: [agro, otherAgro]).rank("гречка аграальянс", history: [])
        require(typoMatches.first?.id == agro.id && typoMatches.first?.evidence?.corrections.isEmpty == false, "brand typo recovered and explained")
        let unrelated = SearchIndex(products: [agro]).rank("полет самолета", history: [], semantic: [agro.id: 0.99])
        require(MealMatcher.suggestion(unrelated) == nil && unrelated.first!.score < 60, "cosine is not confidence or nutrition assignment")
        let milk = Product(id: "milk-test", name: "Молоко 1%", brand: "", basis: .g, source: "synthetic-test")
        let differentMilk = Product(id: "milk-other", name: "Молоко 2%", brand: "", basis: .g, source: "synthetic-test")
        let percentIndex = SearchIndex(products: [differentMilk, milk])
        let disputed = percentIndex.rank("молоко 1% 100%", history: [])
        require(disputed.first?.id == milk.id && disputed.first!.score >= 60, "conflicting fat retains relevant milk as a reviewable suggestion")
        require(MealMatcher.suggestion(disputed) == nil && disputed.first!.evidence!.missing.contains(where: { $0.contains("противоречивые") }), "conflicting percentages are explicit and never confident")
        require(SearchIndex.attributes("молоко 1% 100%")["fat"] == nil, "last percent cannot silently replace first")
        require(MealMatcher.suggestion(percentIndex.rank("молоко 1% 1%", history: []))?.id == milk.id, "repeated identical percent is not a conflict")
        require(MealMatcher.suggestion(percentIndex.rank("молоко 1% нет 2%", history: [])) == nil, "explicit correction is retained for review, not silently chosen")
        let mince = Product(id: "mince-test", name: "Говяжий фарш 4,5%", brand: "", basis: .g, source: "synthetic-test")
        let milkIndex = SearchIndex(products: [mince, milk])
        for noise in ["чьем", "непонятнословечко", "так чьем"] {
            let result = milkIndex.rank(noise + " молоко 1%", history: [], semantic: [milk.id: 0.924, mince.id: 0.99])
            require(result.first?.id == milk.id, "name and fat beat unrelated high vector similarity")
            require(result.first?.evidence?.unrecognizedTerms?.isEmpty == false, "unknown words logged")
            require(MealMatcher.suggestion(result) == nil, "unknown words do not become confident automatic identity")
        }
        require(milkIndex.rank("непонятнословечко молко 1%", history: []).first?.id == milk.id,
            "unknown words cannot suppress typo retrieval before fusion")
        let semanticOnly = milkIndex.rank("напиток", history: [], semantic: [milk.id: 0.95, mince.id: 0.75])
        require(semanticOnly.first?.id == milk.id && MealMatcher.suggestion(semanticOnly) == nil, "semantic discovery retained without lexical evidence")
        let without = milkIndex.rank("чьем молоко 1%", history: [])
        let withVector = milkIndex.rank("чьем молоко 1%", history: [], semantic: [milk.id: 0.95])
        require(withVector.first!.score >= without.first!.score, "supporting vector cannot reduce lexical candidate")
        let five = Product(id: "five-test", name: "Творог 5%", brand: "", basis: .g, source: "synthetic-test")
        let nine = Product(id: "nine-test", name: "Творог 9%", brand: "", basis: .g, source: "synthetic-test")
        require(SearchIndex(products: [nine, five]).rank("творог 5%", history: [], semantic: [nine.id: 0.99]).first?.id == five.id, "explicit fat beats semantic neighbor")
        require(SearchIndex.editDistance("молкоо", "молоко") == 1, "adjacent transposition")
        // Synthetic regression comparison against build 254, not a field accuracy estimate.
        let searchProducts = [agro, otherAgro, rawChicken, friedChicken, five, nine]
        let newSearch = SearchIndex(products: searchProducts)
        let oldSearch = LegacySearchIndex(products: searchProducts)
        let searchCases = [("гречка агро альянс", agro.id), ("гречка аграальянс", agro.id),
            ("гречка агроалянс", agro.id), ("гречка агроальянс", agro.id),
            ("куриная грудка сырая", rawChicken.id), ("куриная грудка жареная", friedChicken.id),
            ("куриная грудка жареняа", friedChicken.id), ("творог 5%", five.id), ("творог 9%", nine.id)]
        var oldTop = 0, newTop = 0
        for (phrase, id) in searchCases {
            if oldSearch.rank(phrase, history: []).first?.id == id { oldTop += 1 }
            if newSearch.rank(phrase, history: []).first?.id == id { newTop += 1 }
        }
        print("Synthetic search top1: legacy \(oldTop)/\(searchCases.count), v2 \(newTop)/\(searchCases.count)")
        let fuzzNames = ["апельсин", "авокадо", "абрикос", "баклажан", "капуста", "картофель", "кефир", "молоко", "говядина", "баранина", "макароны", "морковь"]
        let fuzzProducts = fuzzNames.map { Product(id: "synthetic-" + $0, name: $0, brand: "", basis: .g, source: "synthetic-test") }
        let fuzzNew = SearchIndex(products: fuzzProducts), fuzzOld = LegacySearchIndex(products: fuzzProducts)
        var trials = 0, recoveredOld = 0, recoveredNew = 0, falseAuto = 0
        for name in fuzzNames {
            let chars = Array(name)
            for i in chars.indices {
                var swapped = chars
                if i+1 < chars.count { swapped.swapAt(i,i+1) }
                var deleted = chars; deleted.remove(at:i)
                for query in Set([String(swapped),String(deleted)]) where query != name {
                    trials += 1
                    let expected = "synthetic-" + name
                    if fuzzOld.rank(query, history: []).prefix(5).contains(where: { $0.id == expected }) { recoveredOld += 1 }
                    let ranked = fuzzNew.rank(query, history: [])
                    if ranked.prefix(5).contains(where: { $0.id == expected }) { recoveredNew += 1 }
                    if let automatic = MealMatcher.suggestion(ranked), automatic.id != expected { falseAuto += 1 }
                }
            }
        }
        require(falseAuto == 0, "no false auto choices on synthetic one-word corruptions")
        print("Controlled typo retrieval@5: legacy \(recoveredOld)/\(trials), v2 \(recoveredNew)/\(trials), falseAuto \(falseAuto)")
        for phrase in ["Яблоко сто пятьдеграмм.", "Яблоко сто питдесят грамм."] {
            let damaged = LiveMealParser.parse(phrase)
            require(damaged.rows.count == 1 && damaged.rows[0].food == "яблоко", "damaged mass keeps one food")
            require(damaged.rows[0].amount == nil && damaged.rows[0].requiresAttention && damaged.pending.isEmpty, "damaged mass never becomes 100 or another food")
        }
        require(LiveMealParser.parse("яблоко сто пятьдесят грамм").rows.first?.amount == 150, "complete spoken 150 remains correct")
        let damagedThenNext = LiveMealParser.parse("яблоко сто пятьдеграмм банан 200 грамм")
        require(damagedThenNext.rows.count == 2 && damagedThenNext.rows[0].amount == nil && damagedThenNext.rows[1].food == "банан" && damagedThenNext.rows[1].amount == 200, "damage does not consume following food")
        let weightHint = LiveMealParser.preview("банан")
        require(weightHint.title == "Скажите вес" && weightHint.rows.first?.food == "банан", "product-only preview asks for weight")
        let productHint = LiveMealParser.preview("сто двадцать грамм")
        require(productHint.title == "Скажите продукт" && productHint.rows.first?.amount == 120, "weight-only preview asks for product")
        let emptyHint = LiveMealParser.preview("и еще")
        require(emptyHint.rows.isEmpty, "fillers do not create a placeholder")
        let nextHint = LiveMealParser.preview("банан 120 грамм помидоры")
        require(nextHint.rows.count == 2 && nextHint.rows[1].food == "помидоры" && nextHint.rows[1].amount == nil, "next incomplete product has its own placeholder")
        require(LiveMealParser.preview("творог 5 процентов").title == "Скажите вес", "fat percentage is not weight")
        require(LiveMealParser.preview("банан 2 килограмма").rows.isEmpty, "unsupported quantity does not invent a ready card")
        for text in ["яйцо куриное 120 грамм", "сто двадцать грамм яйца", "яйца сто двадцать", "120 яйца"] {
            let parsed = LiveMealParser.parse(text)
            require(parsed.rows.count == 1 && parsed.rows[0].amount == 120 && parsed.pending.isEmpty, "live pair: \(text)")
        }
        require(LiveMealParser.parse("яйцо куриное").rows.isEmpty, "wait for mass")
        require(LiveMealParser.parse("сто двадцать грамм").rows.isEmpty, "wait for product")
        let tail = LiveMealParser.parse("яйца 120 грамм помидоры")
        require(tail.rows.count == 1 && tail.pending == "помидоры", "next product remains open")
        let two = LiveMealParser.parse("яйца 120 грамм помидоры 60 грамм")
        require(two.rows.count == 2 && two.rows.map(\.amount) == [120, 60], "two consecutive pairs")
        let reversed = LiveMealParser.parse("120 грамм яйца 60 грамм помидоры")
        require(reversed.rows.count == 2 && reversed.rows[1].food == "помидоры", "two weight-first pairs")
        let fat = LiveMealParser.parse("творог 5 процентов 150 грамм")
        require(fat.rows.count == 1 && fat.rows[0].amount == 150 && fat.rows[0].food.contains("5"), "fat is not portion mass")
        require(LiveMealParser.parse("молоко 200 мл").rows.isEmpty, "ml is not g")
        require(LiveMealParser.parse("яйца 120 нет 130 грамм").rows.isEmpty, "correction requires review")
        require(LiveMealParser.parse("банан 12,5 грамма").rows.first?.amount == Decimal(string: "12.5"), "decimal mass")
        require(LiveMealParser.parse("банан ноль грамм").rows.isEmpty, "zero is not a portion")
        for pulseFrames in [1, 2] {
            let click = Array(repeating: Float(0), count: 3200) + Array(repeating: Float(0.05), count: 320 * pulseFrames) + Array(repeating: Float(0), count: 19200)
            var detector = LiveMealEndpoint()
            require(detector.next(click, finished: false) == nil && detector.previewRange == nil && detector.rejectedTransientCount == 1, "isolated pulse is rejected without counting pre-roll as speech")
            var stopped = LiveMealEndpoint()
            require(stopped.next(Array(click.prefix(3200 + 320 * pulseFrames)), finished: true) == nil, "Stop does not bypass transient gate")
        }
        for level: Float in [0.009, 0.05] {
            let shortSpeech = Array(repeating: Float(0), count: 3200) + Array(repeating: level, count: 1600) + Array(repeating: Float(0), count: 19200)
            var detector = LiveMealEndpoint()
            require(detector.next(shortSpeech, finished: false) != nil, "100ms activity just above unchanged threshold remains accepted")
        }
        if let path = ProcessInfo.processInfo.environment["CACALC_TRANSIENT_WAV"] {
            let audio = try LiveWave.samples(Data(contentsOf: URL(fileURLWithPath: path)), finalized: true)
            var detector = LiveMealEndpoint()
            require(detector.next(audio, finished: true) == nil, "real reported click never reaches ASR")
        }
        var endpoint = LiveMealEndpoint()
        let audio = Array(repeating: Float(0), count: 3200) + Array(repeating: Float(0.05), count: 16000) + Array(repeating: Float(0), count: 19200)
        require(endpoint.next(Array(audio.prefix(20000)), finished: false) == nil, "short pause does not close phrase")
        require(endpoint.previewRange != nil, "speech has a preview before the quiet boundary")
        let preview = endpoint.previewRange
        require(endpoint.previewRange == preview, "reading a preview does not consume audio")
        require(endpoint.next(audio, finished: false) != nil, "quiet boundary closes phrase")
        require(endpoint.previewRange == nil, "closed phrase no longer has a speculative preview")
        require(endpoint.next(audio, finished: true) == nil, "same audio cannot emit twice")
        var last = LiveMealEndpoint()
        require(last.next(Array(audio.prefix(18000)), finished: true) != nil, "finish flushes spoken tail")
        // Synthetic continuous speech spanning both former 12 s cut and 16 s read cap.
        let uninterrupted = Array(repeating: Float(0.05), count: 320_000)
        var continuous = LiveMealEndpoint()
        require(continuous.next(Array(uninterrupted.prefix(192_000)), finished: false) == nil,
                "12 seconds never cuts an active word")
        require(continuous.next(uninterrupted, finished: false) == nil,
                "continuous speech remains one revisable phrase after 16 seconds")
        require(continuous.next(uninterrupted, finished: true) == 0..<uninterrupted.count,
                "Stop flushes the complete uncut phrase")
        let uncutMilk = LiveMealParser.parse("Так молоко один процент триста грамм")
        require(uncutMilk.rows.count == 1 && uncutMilk.rows.first?.amount == 300,
                "uncut milk phrase retains three hundred grams")
        require(LiveMealParser.semantic("молоко один процент").rows.isEmpty, "percentage is never a completed weight")
        require(LiveMealParser.semantic("молоко один процент двести").rows.isEmpty, "early matching requires an explicit unit")
        require(LiveMealParser.semantic("молоко один процент двести грамм").rows.first?.amount == 200, "explicit grams complete a semantic pair")
        require(LiveMealParser.semantic("кукурузные хлопья любятово сто грамм ну вот я не понимаю").rows.count == 1, "later conversation cannot reject completed food")
        require(LiveMealParser.semantic("банан сто грамм огурец двести грамм").rows.count == 2, "continuous speech yields two semantic pairs")
        require(LiveMealParser.semantic("350 грамм").rows.isEmpty, "weight alone waits for product")
        require(LiveMealParser.semantic("350 грамм кукурузных хлопьев Любятово").rows.first?.amount == 350, "weight-first pair is available before silence")
        var silence = LiveMealEndpoint()
        require(silence.next(Array(repeating: 0, count: 32000), finished: true) == nil, "silence produces no phrase")

        let logDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("matching-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let testLog = MatchingLog(directory: logDirectory)
        // Real bundled catalog → Product → editable SwiftData override → fresh library.
        let bundledCatalog = Catalog(url: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("ios/Resources/catalog.sqlite"))
        let basicFoods = try await bundledCatalog.browse()
        require(basicFoods.count == 474, "all curated foods visible, no 30/50 row truncation")
        require(basicFoods.allSatisfy { $0.nutrition != nil && $0.barcode == nil && $0.basis == .g }, "complete basic products, no invented barcode")
        let bananas = try await bundledCatalog.search("банан")
        let banana = bananas.first { $0.id == "basic:no:06.525" }!
        require(ProductScope.basic.includes(banana) && !ProductScope.mine.includes(banana), "base scope")
        require(banana.calories == 88 && banana.identitySource?.license == "NLOD", "actual source values and attribution")
        let editingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: editingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: editingDirectory) }
        // Exercise the platform WAV writer, including its still-open file/header.
        let waveURL = editingDirectory.appendingPathComponent("live-fixture.wav")
        var writer: AVAudioFile? = try AVAudioFile(forWriting: waveURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        let pcm = AVAudioPCMBuffer(pcmFormat: writer!.processingFormat, frameCapacity: 16000)!
        pcm.frameLength = 16000
        for i in 0..<16000 { pcm.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.1 }
        try writer!.write(from: pcm)
        let growing = try LiveWave.samples(Data(contentsOf: waveURL))
        require(growing.count > 0, "platform writer exposes PCM before closing")
        try writer!.write(from: pcm)
        let appended = try LiveWave.samples(Data(contentsOf: waveURL))
        require(appended.count > growing.count, "growing WAV exposes appended samples")
        writer = nil
        let completeWave = try LiveWave.samples(Data(contentsOf: waveURL), finalized: true)
        require(completeWave.count == 32000 && abs(completeWave[100] - pcm.floatChannelData![0][100]) < 0.001, "PCM16 WAV decodes actual samples and final size")
        let slice = try LiveWave.read(waveURL, from: 16000, finalized: true, limit: 1000)
        require(slice.totalSamples == 32000 && slice.samples.count == 1000 && abs(slice.samples[100] - completeWave[16100]) < 0.00001, "bounded reader seeks to exact sample")
        var buffered = LiveAudioBuffer(from: 0)
        while buffered.readOffset < completeWave.count {
            let fresh = try LiveWave.read(waveURL, from: buffered.readOffset, finalized: true, limit: 1000)
            buffered.append(fresh.samples)
        }
        require(buffered.samples == completeWave && buffered.samplesRead == 32000 && buffered.reads == 32,
            "incremental WAV path reads every sample once")
        buffered.discard(through: 16000)
        require(buffered.baseSample == 16000 && buffered.samples == Array(completeWave.suffix(16000)),
            "checkpoint discards only committed prefix")
        var cadence = LivePreviewCadence(), previewSamples = 0, previewCalls = 0
        for seconds in 1...48 where cadence.ready(samples: seconds * 16000) {
            previewCalls += 1; previewSamples += seconds * 16000; cadence.completed(samples: seconds * 16000)
        }
        require(previewCalls < 15 && previewSamples < 48 * 16000 * 3,
            "growing preview step bounds repeated audio work without truncating speech")
        let eof = try LiveWave.read(waveURL, from: 32000, finalized: true)
        require(eof.samples.isEmpty, "read at EOF is empty")
        // A long silent prefix must be dropped without losing the next spoken frame.
        var longEndpoint = LiveMealEndpoint()
        var skipped = 0
        for _ in 0..<20 {
            require(longEndpoint.next(Array(repeating: 0, count: 256000), finished: false) == nil, "long silence stays empty")
            let drop = longEndpoint.discardableSamples
            skipped += drop
            longEndpoint.discardPrefix(drop)
            require(longEndpoint.cursor <= 3200, "silence retains bounded pre-roll")
        }
        require(skipped > 120 * 16000, "processing crosses former two-minute limit")
        let speechAfterSilence = Array(repeating: Float(0), count: 3200) + Array(repeating: Float(0.05), count: 8000) + Array(repeating: Float(0), count: 19200)
        require(longEndpoint.next(speechAfterSilence, finished: false) != nil, "speech after long silence is retained")
        let editingURL = editingDirectory.appendingPathComponent("editing.store")
        do {
            let container = try DiaryStore.makeContainer(url: editingURL)
            let lib = ProductLibrary(container: container, catalog: bundledCatalog)
            await lib.load()
            require(lib.products.count == basicFoods.count, "library displays base without personal records")
            await lib.begin(banana)
            lib.draft?.name = "Мой банан"; lib.draft?.calories = "91"
            await lib.commit()
            require(lib.error == nil && lib.draft == nil, "basic editing succeeds without barcode")
            let backups = editingDirectory.appendingPathComponent("daily-backups")
            let snapshot = try DailyStoreBackup.create(store: editingURL, root: backups, day: "2026-09-15")!
            let restored = try DiaryStore.makeContainer(url: snapshot.appendingPathComponent("default.store"))
            let restoredLibrary = ProductLibrary(container: restored, catalog: bundledCatalog)
            await restoredLibrary.load()
            require(restoredLibrary.products.first { $0.id == banana.id }?.name == "Мой банан", "daily SQLite snapshot reopens through real SwiftData and includes committed changes")
            let repeatedBackup = try DailyStoreBackup.create(store: editingURL, root: backups, day: "2026-09-15")
            require(repeatedBackup == nil, "daily backup never overwrites the same day's snapshot")
            require(ProcessMemory.fields()["physicalFootprintBytes"].flatMap(UInt64.init) ?? 0 > 0, "OS process memory measurement returns a real footprint")

        }
        do {
            let container = try DiaryStore.makeContainer(url: editingURL)
            let lib = ProductLibrary(container: container, catalog: bundledCatalog)
            await lib.load()
            require(lib.products.count == basicFoods.count, "override does not duplicate base row")
            let edited = lib.products.first { $0.id == banana.id }!
            require(ProductScope.basic.includes(edited) && !ProductScope.mine.includes(edited), "edited basic product stays basic")
            let custom = Product(id: "custom", name: "Мой продукт", brand: "", basis: .g, source: "user-label")
            require(ProductScope.mine.includes(custom) && !ProductScope.basic.includes(custom) && ProductScope.all.includes(custom), "custom product scopes")
            require(edited.calories == 91 && edited.name == "Мой банан" && edited.identitySource == banana.identitySource, "edit and provenance survive reopen")
            let store = DiaryStore(container: container, catalog: bundledCatalog)
            let matches = try await store.search("банан")
            require(matches.first { $0.id == banana.id }?.calories == 91, "meal search uses personal override")
            let baseAgain = try await bundledCatalog.search("банан")
            require(baseAgain.first { $0.id == banana.id }?.calories == 88, "original source untouched")
        }
        do {
            let container = try DiaryStore.makeContainer(url: editingURL)
            let store = DiaryStore(container: container, catalog: bundledCatalog)
            let repo = MealRepository(container: container)
            let row = MealRow(food: "банан", quantity: "100", unit: .g, product: banana)
            var draft = MealDraft(day: Day(Date()), meal: .lunch); draft.rows = [row]
            try await repo.commit(draft)
            try await repo.commit(draft)
            let usage = try await repo.usage()
            require(usage.first?.count == 1, "resaving does not inflate real usage")
            _ = try await store.productRepository.searchIndex(bundledCatalog)
            await store.productRepository.injectSaveFailure()
            do { try await store.productRepository.remove(banana); fatalError("deletion should roll back") } catch {}
            let before = try await store.productRepository.hiddenIDs()
            require(!before.contains(banana.id), "failed tombstone rolls back")
            try await store.productRepository.remove(banana)
            let lib = ProductLibrary(container: container, catalog: bundledCatalog); await lib.load()
            require(!lib.products.contains { $0.id == banana.id }, "deleted basic absent from library")
            let search = try await store.search("банан")
            require(!search.contains { $0.id == banana.id }, "deleted basic absent from search")
            let session = MealSession(store: store, diagnosticLog: testLog)
            let ranked = try await session.matches("банан")
            require(!ranked.contains { $0.id == banana.id }, "deleted basic not resurrected by history")
            let page = try await repo.page(for: draft.day)
            require(page.items.contains { $0.id == row.id && $0.row.product?.id == banana.id }, "deletion preserves historical snapshot")
        }
        do {
            let repo = ProductRepository(container: try DiaryStore.makeContainer(url: editingURL))
            let hidden = try await repo.hiddenIDs()
            require(hidden.contains(banana.id), "tombstone survives reopen")
        }
        // Disk-backed v3 → v4 migration, reset and reopen: diary bytes must not change.
        let resetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: resetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resetDirectory) }
        let resetURL = resetDirectory.appendingPathComponent("reset.store")
        let synthetic = Product(id: "reset-food", name: "Тест", brand: "", basis: .g, source: "synthetic-test")
        let productBytes = try JSONEncoder().encode(synthetic)
        let diaryBytes = Data("preserved journal snapshot".utf8)
        do {
            let schema = Schema(versionedSchema: PersonalSchemaV3.self)
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: resetURL, cloudKitDatabase: .none)])
            let db = ModelContext(old)
            db.insert(PersonalSchema.PersonalProduct(synthetic, data: productBytes))
            db.insert(PersonalSchemaV3.ChoiceRecord(phrase: "тест", product: synthetic, data: productBytes, now: Date()))
            db.insert(PersonalSchemaV3.JournalRecord(id: UUID(), day: Day(Date()), meal: .breakfast, data: diaryBytes))
            db.insert(PersonalSchema.Record(id: UUID(), day: Day(Date()), meal: .lunch, productData: productBytes, amount: "100", unit: .g))
            db.insert(PersonalSchemaV3.MealDraftRecord(diaryBytes))
            try db.save()
        }
        do {
            let migrated = try DiaryStore.makeContainer(url: resetURL)
            try CatalogReset.apply(to: migrated)
            let db = ModelContext(migrated)
            let products = try db.fetch(FetchDescriptor<PersonalSchema.PersonalProduct>())
            let choices = try db.fetch(FetchDescriptor<PersonalSchemaV3.ChoiceRecord>())
            let journal = try db.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>())
            let legacy = try db.fetch(FetchDescriptor<PersonalSchema.Record>())
            let drafts = try db.fetch(FetchDescriptor<PersonalSchemaV3.MealDraftRecord>())
            require(products.isEmpty && choices.isEmpty, "catalog and matching memory cleared")
            require(journal.count == 1 && journal[0].data == diaryBytes && legacy.count == 1 && legacy[0].productData == productBytes, "both diary generations preserved")
            require(drafts.first?.data == diaryBytes, "meal draft preserved")
            db.insert(PersonalSchema.PersonalProduct(synthetic, data: productBytes)); try db.save()
        }
        do {
            let reopened = try DiaryStore.makeContainer(url: resetURL)
            try CatalogReset.apply(to: reopened)
            let products = try ModelContext(reopened).fetch(FetchDescriptor<PersonalSchema.PersonalProduct>())
            require(products.count == 1, "new personal cards survive next launch")
        }
        // History reset must leave the exact goal/product bytes and survive reopening.
        let goalBytes = Data("synthetic goal bytes".utf8)
        do {
            let container = try DiaryStore.makeContainer(url: resetURL)
            let db = ModelContext(container)
            db.insert(PersonalSchema.GoalRecord(day: "2026-09-15", data: goalBytes))
            db.insert(PersonalSchema.DraftRecord(diaryBytes))
            db.insert(PersonalSchemaV2.ProductDraftRecord(productBytes))
            db.insert(PersonalSchemaV3.ChoiceRecord(phrase: "тест", product: synthetic, data: productBytes, now: Date()))
            try db.save()
            try HistoryReset.apply(to: container)
        }
        do {
            let container = try DiaryStore.makeContainer(url: resetURL)
            let db = ModelContext(container)
            let historyCheck1 = try db.fetchCount(FetchDescriptor<PersonalSchema.Record>()) == 0
            require(historyCheck1, "legacy history cleared")
            let historyCheck2 = try db.fetchCount(FetchDescriptor<PersonalSchemaV3.JournalRecord>()) == 0
            require(historyCheck2, "journal history cleared")
            let historyCheck3 = try db.fetchCount(FetchDescriptor<PersonalSchema.DraftRecord>()) == 0
            require(historyCheck3, "old food draft cleared")
            let historyCheck4 = try db.fetchCount(FetchDescriptor<PersonalSchemaV3.MealDraftRecord>()) == 0
            require(historyCheck4, "meal draft cleared")
            let historyCheck5 = try db.fetchCount(FetchDescriptor<PersonalSchemaV3.ChoiceRecord>()) == 0
            require(historyCheck5, "test choice history cleared")
            let historyCheck6 = try db.fetch(FetchDescriptor<PersonalSchema.GoalRecord>()).first?.data == goalBytes
            require(historyCheck6, "goal bytes unchanged")
            let historyCheck7 = try db.fetch(FetchDescriptor<PersonalSchema.PersonalProduct>()).first?.data == productBytes
            require(historyCheck7, "personal products unchanged")
            let historyCheck8 = try db.fetch(FetchDescriptor<PersonalSchemaV2.ProductDraftRecord>()).first?.data == productBytes
            require(historyCheck8, "product draft unchanged")
            db.insert(PersonalSchemaV3.JournalRecord(id: UUID(), day: Day(Date()), meal: .breakfast, data: diaryBytes))
            try db.save()
            try HistoryReset.apply(to: container)
            let historyCheck9 = try ModelContext(container).fetchCount(FetchDescriptor<PersonalSchemaV3.JournalRecord>()) == 1
            require(historyCheck9, "repeat reset preserves new meals")
        }
        let decoded = try ExtractedMeal.decode("Салат от ВкусВилла|325\nТворог, который купил вчера|23,5\nБанан|?")
        require(decoded.items.count == 3, "rows")
        require(decoded.items[1].food == "Творог, который купил вчера", "full description")
        require(decoded.items[1].amount == Decimal(string: "23.5"), "decimal comma")
        require(decoded.items[0].unit == .g && decoded.items[2].unit == nil, "gram contract")
        for invalid in ["", "рис|0", "рис|-5", "рис|NaN", "рис|1e2", "рис|2|g", "рис|330ml", "|2", "рис|2\n-", "```\nрис|2\n```"] {
            do { _ = try ExtractedMeal.decode(invalid); fatalError("Accepted invalid output: \(invalid)") }
            catch {}
        }
        let legacy = try ExtractedMeal.decode(#"{"i":[["рис",2,"g"]]}"#)
        require(legacy.items[0].amount == 2, "legacy pending response")
        let empty = try ExtractedMeal.decode("-"); require(empty.items.isEmpty, "no food")
        let withGrams = try ExtractedMeal.decode("Молоко|250 грамм\nЯйца|119 г\nТворог|200г.\nМасло|0,05 грамма")
        require(withGrams.items.map(\.amount) == [250, 119, 200, Decimal(string: "0.05")], "gram suffix tolerance")
        for invalid in ["рис|0.25 кг", "рис|250mg", "рис|двести грамм", "рис|250 грамм мусор"] {
            do { _ = try ExtractedMeal.decode(invalid); fatalError("Accepted wrong unit or malformed suffix") } catch {}
        }
        for placeholder in ["-|?", "?|?", "|?", "...|?"] {
            let result = try ExtractedMeal.decode(placeholder)
            require(result.items.isEmpty, "no phantom food")
        }
        let mixed = try ExtractedMeal.decode("-|?\nБанан|?")
        require(mixed.items.count == 1 && mixed.items[0].food == "Банан", "real food without weight retained")
        let raw = "Салат от ВкусВилла|325\nТворог, который купил вчера|23,5\nБанан|?"
        let api = MealAPI(transport: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            require(body["model"] as? String == "openai/gpt-5.6-luna", "model")
            require((body["reasoning"] as? [String:String])?["effort"] == "low", "effort")
            require(body["response_format"] == nil, "no JSON schema")
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason":"stop", "message":["content":raw]]], "usage":["prompt_tokens":200,"completion_tokens":40]])
            try await Task.sleep(for: .milliseconds(80))
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let store = DiaryStore(container: try DiaryStore.makeContainer(memory: true), catalog: Catalog(url: nil))
        let quickContainer = try DiaryStore.makeContainer(memory: true)
        let quickStore = DiaryStore(container: quickContainer, catalog: Catalog(url: nil))
        let quick = MealSession(store: quickStore, diagnosticLog: testLog)
        await quick.begin(day: quickStore.today)
        let quickOwner = quick.draft!.id
        var manual = MealRow(food: "Разовая еда")
        manual.manualNutrition = PortionSnapshot(calories: 123.5, protein: 2.5, fat: 0, carbs: 20)
        try await quick.saveQuickEntry(manual, owner: quickOwner)
        let restoredQuick = try await quick.repository.loadDraft()!
        require(restoredQuick.rows[0].portion.protein == 2.5 && !restoredQuick.rows[0].requiresAttention, "quick nutrition persists without quantity/product")
        manual.food = "Исправленная еда"
        try await quick.saveQuickEntry(manual, owner: quickOwner)
        require(quick.draft!.rows.count == 1, "editing quick entry preserves identity")
        try await quick.flush()
        try await quick.repository.commit(quick.draft!)
        let quickDB = ModelContext(quickContainer)
        let quickRecords = try quickDB.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>())
        let savedQuick = try JSONDecoder().decode(MealRow.self, from: quickRecords[0].data)
        require(savedQuick.manualNutrition == manual.manualNutrition && savedQuick.product == nil, "journal preserves exact one-off values")
        let quickHistory = try await quick.repository.history()
        require(quickHistory.isEmpty, "quick entry does not teach product matching")
        let quickProducts = try quickDB.fetchCount(FetchDescriptor<PersonalSchema.PersonalProduct>())
        require(quickProducts == 0, "quick entry does not create a product")
        var badQuick = manual
        badQuick.manualNutrition?.fat = -1
        require((try? badQuick.validated()) == nil, "negative manual nutrition rejected")
        // Spoken portions use active batches only and become editable gram snapshots.
        let servingStore = DiaryStore(container: try DiaryStore.makeContainer(url: editingDirectory.appendingPathComponent("servings.store")), catalog: bundledCatalog)
        let servingPrep = PreparedRepository(container: servingStore.container)
        let servingIngredient = Product(id: "synthetic-serving-lentil", name: "Чечевица", brand: "", basis: .g,
            calories: 300, protein: 20, fat: 2, carbs: 50, source: "synthetic-test")
        let servingState = CookingState(recipe: RecipeTemplate(name: "Чечевица", ingredients: [
            RecipeIngredient(product: servingIngredient, planned: "250", actual: "250")]), yieldText: "840", portionText: "4")
        try servingPrep.create(servingState)
        let servingBatch = try servingPrep.stocks()[0].batch
        let servingLexicon = MealPairParser.Lexicon(index: SearchIndex(products: [servingBatch.product]))
        for phrase in ["порция чечевицы", "чечевица порция", "одна порция чечевицы", "порцию чечевицы"] {
            let result = MealPairParser.analyze(phrase, lexicon: servingLexicon, final: true).result
            require(result.rows.count == 1 && result.rows[0].unit == .portion && result.rows[0].amount == 1, "singular serving grammar: " + phrase)
        }
        let pairServings = MealPairParser.analyze("две порции чечевицы", lexicon: servingLexicon, final: true).result
        require(pairServings.rows.count == 1 && pairServings.rows[0].amount == 2, "explicit serving count")
        require(MealPairParser.analyze("порция", lexicon: servingLexicon, final: true).result.rows.isEmpty, "serving without food stays pending")
        let servingSession = MealSession(store: servingStore, diagnosticLog: testLog)
        await servingSession.begin(day: servingStore.today)
        let servingOwner = servingSession.draft!.id
        servingSession.draft?.audioFile = "servings.wav"; servingSession.draft?.dictationID = UUID()
        try await servingSession.acceptLiveHypothesis("чечевица порция", owner: servingOwner, file: "servings.wav")
        await servingSession.waitForLiveMatching()
        var servingRow = servingSession.draft!.rows[0]
        require(servingRow.product?.preparedBatchID == servingBatch.id && servingRow.amount == 210 && servingRow.unit == .g && servingRow.batchPortions == 1, "live serving finds batch and resolves 840/4 grams")
        let stockBeforeSaving = try servingPrep.stocks()[0]
        require(stockBeforeSaving.grams == 840, "draft serving does not consume stock")
        try await servingSession.acceptLiveHypothesis("чечевица порция", owner: servingOwner, file: "servings.wav")
        require(servingSession.draft!.rows.count == 1 && servingSession.draft!.rows[0].amount == 210, "ASR replay preserves resolved grams")
        try await servingSession.acceptLiveHypothesis("чечевица две порции", owner: servingOwner, file: "servings.wav")
        require(servingSession.draft!.rows[0].amount == 420 && servingSession.draft!.rows[0].batchPortions == 2, "revised serving count recalculates grams")
        try await servingSession.acceptLiveHypothesis("чечевица 300 грамм", owner: servingOwner, file: "servings.wav")
        await servingSession.waitForLiveMatching()
        require(servingSession.draft!.rows[0].amount == 300 && servingSession.draft!.rows[0].requestedPreparedPortions == nil, "ASR correction from serving to grams")
        try await servingSession.acceptLiveHypothesis("чечевица две порции", owner: servingOwner, file: "servings.wav")
        await servingSession.waitForLiveMatching()
        require(servingSession.draft!.rows[0].amount == 420 && servingSession.draft!.rows[0].unit == .g, "ASR correction from grams back to servings rematches batch")
        servingSession.updateRow(servingRow.id) { $0.quantity = "390" }
        try await servingSession.acceptLiveHypothesis("чечевица две порции", owner: servingOwner, file: "servings.wav")
        servingRow = servingSession.draft!.rows[0]
        require(servingRow.amount == 390 && servingRow.unit == .g && servingRow.batchPortions == 2, "ASR replay preserves manually corrected grams and consumption count")
        try await servingSession.flush()
        try await servingSession.repository.commit(servingSession.draft!)
        let servingRemaining = try PreparedRepository(container: servingStore.container).stocks()[0]
        require(servingRemaining.grams == 450 && servingRemaining.portions == 2 && servingRemaining.nextGrams == 225, "commit consumes visible grams and requested portions")
        var manualServing = MealRow(food: "чечевица", quantity: "1", unit: .portion)
        servingSession.draft = MealDraft(day: servingStore.today, meal: .lunch, rows: [manualServing])
        servingSession.choose(servingBatch.product, for: manualServing.id)
        require(servingSession.draft!.rows[0].amount == 225 && servingSession.draft!.rows[0].unit == .g, "manual candidate choice uses new remaining stock")
        try await servingSession.flush()
        let servingReload = MealSession(store: servingStore, diagnosticLog: testLog)
        await servingReload.load()
        require(servingReload.draft?.rows[0].amount == 225 && servingReload.draft?.rows[0].requestedPreparedPortions == 1, "resolved serving survives draft reload")
        servingReload.choose(servingIngredient, for: manualServing.id)
        require(servingReload.draft?.rows[0].product?.preparedBatchID == servingBatch.id, "ordinary product cannot silently replace prepared serving")
        manualServing.id = UUID()
        servingReload.draft?.rows = [manualServing]
        try servingPrep.close(servingBatch)
        servingReload.choose(servingBatch.product, for: manualServing.id)
        require(servingReload.draft?.rows[0].product == nil && servingReload.draft?.rows[0].unit == .portion, "finished batch has no invented gram weight")
        // Nonterminating division still fits the persisted quantity contract.
        var thirds = servingState
        thirds.draftID = UUID()
        thirds.yieldText = "100"; thirds.portionText = "3"
        try servingPrep.create(thirds)
        let thirdBatch = try PreparedRepository(container: servingStore.container).stocks().first { $0.active }!.batch
        servingReload.choose(thirdBatch.product, for: manualServing.id)
        require(servingReload.draft!.rows[0].amount != nil && (try? servingReload.draft!.rows[0].validated()) != nil, "100/3 portion grams remain valid Decimal input")
        // User case: 505 g / 3 servings must never leak an 18-digit fraction into UI.
        try servingPrep.adjust(thirdBatch.id, grams: 505, portions: 3)
        servingReload.choose(thirdBatch.product, for: manualServing.id)
        let riceThird = servingReload.draft!.rows[0]
        require(riceThird.quantityEditingText == "168,3" && riceThird.quantityLabel == "168,3 г", "automatic third has compact display and editable text")
        require(riceThird.amount! > Decimal(string: "168.3")!, "display does not round stored quantity")
        try await servingReload.flush()
        let riceReopened = MealSession(store: servingStore, diagnosticLog: testLog)
        await riceReopened.load()
        require(riceReopened.draft!.rows[0].quantity == riceThird.quantity && riceReopened.draft!.rows[0].quantityEditingText == "168,3", "existing precise draft keeps compact display after reopen")
        riceReopened.updateRow(riceThird.id) { $0.quantity = "170,25" }
        require(riceReopened.draft!.rows[0].amount == Decimal(string: "170.25")! && riceReopened.draft!.rows[0].quantityEditingText == "170,25", "manual decimal remains editable without formatting interference")
        try await servingReload.flush()
        try await servingReload.repository.commit(servingReload.draft!)
        let riceStock = try servingPrep.stocks().first { $0.id == thirdBatch.id }!
        require(riceStock.grams == 505 - riceThird.amount! && riceStock.portions == 2, "display rounding does not affect stock deduction")
        require(Numbers.display(Decimal(string: "1168.333333333333333333")!, grouping: false) == "1168,3", "editable weight has no nonbreaking thousands separator")
        thirds.draftID = UUID()
        try servingPrep.create(thirds)
        let ambiguousServings = try await servingReload.matches("чечевица", preparedOnly: true)
        require(ambiguousServings.count == 2 && MealMatcher.suggestion(ambiguousServings) == nil, "identical active dishes require a choice")
        require(ambiguousServings.allSatisfy { $0.product.preparedBatchID != nil }, "prepared alternatives contain no raw products")
        for activeStock in try PreparedRepository(container: servingStore.container).stocks().filter(\.active) { try servingPrep.close(activeStock.batch) }
        let noServings = try await servingReload.matches("чечевица", preparedOnly: true)
        require(noServings.isEmpty, "portion matching never falls back to raw catalog lentils")
        // Real persistence across pauses INSIDE a pair and inside a spoken number.
        let pauseStore = DiaryStore(container: try DiaryStore.makeContainer(url: editingDirectory.appendingPathComponent("pauses.store")), catalog: bundledCatalog)
        let paused = MealSession(store: pauseStore, diagnosticLog: testLog)
        await paused.begin(day: pauseStore.today)
        let pauseOwner = paused.draft!.id
        paused.draft?.audioFile = "pauses.wav"; paused.draft?.dictationID = UUID()
        try await paused.acceptLiveHypothesis("Thank you!", owner: pauseOwner, file: "pauses.wav")
        require(paused.draft!.rows.isEmpty && paused.liveProgress?.phrase == "", "filtered noise does not appear in live preview")
        try await paused.acceptLivePhrase("Yeah.", through: 8000, owner: pauseOwner, file: "pauses.wav", boundary: true)
        require(paused.draft!.rows.isEmpty && paused.draft?.livePendingText == "" && paused.draft?.transcript == "Yeah.", "noise advances audio cursor and preserves raw text without adding pending food")

        try await paused.acceptLivePhrase("350 грамм", through: 16000, owner: pauseOwner, file: "pauses.wav", boundary: true)
        require(paused.draft!.rows.isEmpty, "a pause after weight alone doesn't invent food")
        try await paused.flush()
        let resumePause = MealSession(store: pauseStore, diagnosticLog: testLog)
        await resumePause.load()
        try await resumePause.acceptLivePhrase("яблок", through: 32000, owner: pauseOwner, file: "pauses.wav", boundary: true)
        try await resumePause.acceptLivePhrase("банан 100 грамм", through: 48000, owner: pauseOwner, file: "pauses.wav", boundary: true)
        require(resumePause.draft!.rows.map(\.amount) == [350, 100], "pause joins weight-first pair, next pair stays separate")
        try await resumePause.acceptLivePhrase("яблоко сто", through: 64000, owner: pauseOwner, file: "pauses.wav", boundary: true)
        try await resumePause.acceptLivePhrase("пятьдесят грамм", through: 80000, owner: pauseOwner, file: "pauses.wav", boundary: true)
        require(resumePause.draft!.rows.last?.amount == 150, "pause inside 150 never produces 100 and 50")
        try await resumePause.acceptLivePhrase("молоко один", through: 96000, owner: pauseOwner, file: "pauses.wav", boundary: true)
        try await resumePause.acceptLivePhrase("процент триста грамм", through: 112000, owner: pauseOwner, file: "pauses.wav", boundary: true)
        require(resumePause.draft!.rows.last?.amount == 300 && resumePause.draft!.rows.last?.food == "молоко 1%", "pause inside percent retains the characteristic")
        await resumePause.waitForLiveMatching()
        // Later ASR inserts food before an existing manually edited row.
        try await resumePause.acceptLiveHypothesis("банан 100 грамм", owner: pauseOwner, file: "pauses.wav")
        let insertedBananaID = resumePause.draft!.rows.last!.id
        resumePause.updateRow(insertedBananaID) { $0.quantity = "125" }
        try await resumePause.acceptLiveHypothesis("350 грамм яблок банан 100 грамм", owner: pauseOwner, file: "pauses.wav")
        require(resumePause.draft!.rows.first(where: { $0.id == insertedBananaID })?.amount == 125,
                "ASR insertion before a row cannot transfer or erase its manual weight")
        await resumePause.waitForLiveMatching()
        // Actual session path: preview -> pause -> matching -> reopen -> next food.
        let hamStore = DiaryStore(container: try DiaryStore.makeContainer(url: editingDirectory.appendingPathComponent("ham.store")), catalog: bundledCatalog)
        var hamLabel = ProductCreationDraft(product: compoundProducts[0])
        hamLabel.calories = "100"; hamLabel.protein = "12"; hamLabel.fat = "5"; hamLabel.carbs = "1"
        let savedHam = try await hamStore.productRepository.commit(hamLabel)
        let hamSession = MealSession(store: hamStore, diagnosticLog: testLog)
        await hamSession.begin(day: hamStore.today)
        let hamOwner = hamSession.draft!.id
        hamSession.draft?.audioFile = "ham.wav"; hamSession.draft?.dictationID = UUID()
        try await hamSession.acceptLiveHypothesis("Ветчина из филе индейки Индилайт", owner: hamOwner, file: "ham.wav")
        require(hamSession.draft!.rows.isEmpty, "name alone does not invent ham quantity")
        try await hamSession.acceptLiveHypothesis(hamPhrase, owner: hamOwner, file: "ham.wav")
        require(hamSession.draft!.rows.count == 1 && hamSession.draft!.rows[0].amount == 50,
                "completed ham appears during growing ASR hypothesis")
        let hamID = hamSession.draft!.rows[0].id
        try await hamSession.acceptLivePhrase(hamPhrase, through: 16000, owner: hamOwner, file: "ham.wav", boundary: true)
        await hamSession.waitForLiveMatching()
        require(hamSession.draft!.rows.count == 1 && hamSession.draft!.rows[0].id == hamID &&
                hamSession.draft!.rows[0].product?.id == savedHam.id && hamSession.draft!.livePendingText == "",
                "pause preserves ham row ID, selects its card and clears pending speech")
        try await hamSession.flush()
        let hamReopened = MealSession(store: hamStore, diagnosticLog: testLog)
        await hamReopened.load()
        require(hamReopened.draft!.rows[0].id == hamID && hamReopened.draft!.rows[0].amount == 50 &&
                hamReopened.draft!.livePendingText == "", "completed ham survives reopening")
        try await hamReopened.acceptLivePhrase("Далее молоко 100 грамм", through: 32000, owner: hamOwner, file: "ham.wav", boundary: true)
        await hamReopened.waitForLiveMatching()
        require(hamReopened.draft!.rows.map(\.amount) == [50, 100] && hamReopened.draft!.rows[0].id == hamID &&
                hamReopened.draft!.rows[1].food == "молоко" && hamReopened.draft!.livePendingText == "",
                "following food does not attach to completed ham or duplicate it")
        let repeatedSession = MealSession(store: hamStore, diagnosticLog: testLog)
        await repeatedSession.begin(day: hamStore.today)
        let repeatedOwner = repeatedSession.draft!.id
        repeatedSession.draft?.audioFile = "repeated-ham.wav"; repeatedSession.draft?.dictationID = UUID()
        try await repeatedSession.acceptLiveHypothesis("Ветчина из филе индейки Индилайт", owner: repeatedOwner, file: "repeated-ham.wav")
        require(repeatedSession.draft!.rows.isEmpty, "first incomplete ham hypothesis remains open")
        let repeatedPhrase = hamPhrase + " пятьдесят грамм"
        try await repeatedSession.acceptLiveHypothesis(repeatedPhrase, owner: repeatedOwner, file: "repeated-ham.wav")
        require(repeatedSession.draft!.rows.count == 1 && repeatedSession.draft!.rows[0].amount == 50,
                "first complete hypothesis may already contain a repeated weight")
        let repeatedID = repeatedSession.draft!.rows[0].id
        repeatedSession.updateRow(repeatedID) { $0.quantity = "75" }
        try await repeatedSession.acceptLiveHypothesis(repeatedPhrase + " 50 грамм", owner: repeatedOwner, file: "repeated-ham.wav")
        try await repeatedSession.acceptLivePhrase(repeatedPhrase, through: 16000, owner: repeatedOwner, file: "repeated-ham.wav", boundary: true)
        await repeatedSession.waitForLiveMatching()
        require(repeatedSession.draft!.rows.count == 1 && repeatedSession.draft!.rows[0].id == repeatedID &&
                repeatedSession.draft!.rows[0].amount == 75 && repeatedSession.draft!.rows[0].product?.id == savedHam.id &&
                repeatedSession.draft!.livePendingText == "",
                "repeated ASR weights preserve manual grams, row identity and card across the final phrase")
        try await repeatedSession.flush()
        let repeatedRecovered = MealSession(store: hamStore, diagnosticLog: testLog)
        await repeatedRecovered.resume(repeatedOwner)
        try await repeatedRecovered.acceptLivePhrase("Далее молоко 100 грамм", through: 32000, owner: repeatedOwner, file: "repeated-ham.wav", boundary: true)
        await repeatedRecovered.waitForLiveMatching()
        require(repeatedRecovered.draft!.rows.map(\.amount) == [75, 100] && repeatedRecovered.draft!.rows[0].id == repeatedID &&
                repeatedRecovered.draft!.livePendingText == "", "reopened repeated-weight recording continues with an independent food")
        // Regression: a final two-food preview leaves one unused animation slot.
        // Starting the next recording must not reuse the committed milk row's ID.
        let slotStore = DiaryStore(container: try DiaryStore.makeContainer(url: editingDirectory.appendingPathComponent("slots.store")), catalog: bundledCatalog)
        let slots = MealSession(store: slotStore, diagnosticLog: testLog)
        await slots.begin(day: slotStore.today)
        let slotOwner = slots.draft!.id
        slots.draft?.dictationID = UUID()
        slots.draft?.audioFile = "slots.wav"
        slots.draft?.liveMode = true
        slots.showLiveText("")
        try await slots.acceptLiveHypothesis("яблоко сто пятьдесят грамм молоко один процент", owner: slotOwner, file: "slots.wav")
        try await slots.acceptLivePhrase("яблоко сто пятьдесят грамм молоко один процент триста грамм", through: 128000, owner: slotOwner, file: "slots.wav", boundary: true)
        await slots.waitForLiveMatching()
        require(slots.draft!.rows.count == 2, "two foods committed before recording restart")
        let committedIDs = Set(slots.draft!.rows.map(\.id))
        slots.liveProgress = nil
        slots.draft?.dictationID = UUID()
        slots.draft?.audioFile = "slots-next.wav"
        slots.draft?.liveAudioSampleOffset = 0
        slots.showLiveText("")
        require(!committedIDs.contains(slots.liveInputID), "new recording placeholder must not duplicate a committed row ID")
        try await slots.acceptLivePhrase("банан 100 грамм", through: 16000, owner: slotOwner, file: "slots-next.wav", boundary: true)
        await slots.waitForLiveMatching()
        require(Set(slots.draft!.rows.map(\.id)).count == 3, "next recording appends a uniquely identified food")
        let milkID = slots.draft!.rows[1].id
        slots.removeRows([milkID])
        require(slots.draft!.rows.count == 2 && slots.draft!.rows.last?.food == "банан", "deleting milk leaves other foods intact")
        let liveStore = DiaryStore(container: try DiaryStore.makeContainer(url: editingDirectory.appendingPathComponent("live.store")), catalog: bundledCatalog)
        let identityStore = DiaryStore(container: try DiaryStore.makeContainer(url: editingDirectory.appendingPathComponent("identity.store")), catalog: bundledCatalog)
        var identityDraft = ProductCreationDraft(product: cereal)
        identityDraft.calories = "378"; identityDraft.protein = "7.8"
        identityDraft.fat = "1.1"; identityDraft.carbs = "82.1"
        _ = try await identityStore.productRepository.commit(identityDraft)
        let gramsStore = DiaryStore(container: try DiaryStore.makeContainer(url: editingDirectory.appendingPathComponent("grams.store")), catalog: bundledCatalog)
        let gramsSession = MealSession(store: gramsStore, diagnosticLog: testLog)
        await gramsSession.begin(day: gramsStore.today)
        let gramsOwner = gramsSession.draft!.id
        gramsSession.draft?.audioFile = "grams.wav"
        try await gramsSession.acceptLivePhrase("Апельсин двести семьдесят пять.", through: 56640, owner: gramsOwner, file: "grams.wav", boundary: true)
        require(gramsSession.draft!.rows.count == 1 && gramsSession.draft!.rows[0].amount == 275 && gramsSession.draft!.rows[0].unit == .g, "unlabelled weight is grams at pause")
        let orangeID = gramsSession.draft!.rows[0].id
        try await gramsSession.acceptLivePhrase("", through: 70000, owner: gramsOwner, file: "grams.wav", boundary: true)
        try await gramsSession.acceptLivePhrase("Gram.", through: 126720, owner: gramsOwner, file: "grams.wav", boundary: true)
        try await gramsSession.acceptLivePhrase("Дальше.", through: 294720, owner: gramsOwner, file: "grams.wav", boundary: true)
        try await gramsSession.acceptLivePhrase("Яблоко сто двадцать грамм.", through: 390080, owner: gramsOwner, file: "grams.wav", boundary: true)
        await gramsSession.waitForLiveMatching()
        require(gramsSession.draft!.rows.count == 2 && gramsSession.draft!.rows[0].id == orangeID && gramsSession.draft!.rows[1].amount == 120, "late gram never duplicates or blocks following apple")
        let gramsLexicon = MealPairParser.Lexicon(index: SearchIndex(products: [Product(id: "synthetic-seven", name: "Круассан 7 дней", brand: "", basis: .g, source: "synthetic")]))
        for phrase in ["апельсин 275", "апельсин 275 грамм", "275 грамм апельсина", "апельсин 275. Gram."] {
            let result = MealPairParser.analyze(phrase, lexicon: gramsLexicon, final: true).result
            require(result.rows.count == 1 && result.rows[0].amount == 275 && result.rows[0].unit == .g, "optional gram forms: " + phrase)
        }
        let unsupportedCount = MealPairParser.analyze("275 апельсина", lexicon: gramsLexicon, final: true).result
        require(unsupportedCount.rows.isEmpty && !unsupportedCount.pending.isEmpty, "quantity before food needs an explicit unit")
        require(MealPairParser.analyze("молоко 1%", lexicon: gramsLexicon, final: true).result.rows.isEmpty, "percent is not grams")
        let numericFood = MealPairParser.analyze("круассан семь дней 80", lexicon: gramsLexicon, final: true).result
        require(numericFood.rows.count == 1 && numericFood.rows[0].amount == 80 && numericFood.rows[0].food.contains("7"), "known numeric name preserved")
        require(MealPairParser.analyze("апельсин сто", lexicon: gramsLexicon).result.rows.isEmpty, "unfinished live number can grow")
        let identitySession = MealSession(store: identityStore, diagnosticLog: testLog)
        await identitySession.begin(day: identityStore.today)
        let identityOwner = identitySession.draft!.id
        identitySession.draft?.audioFile = "identity.wav"
        try await identitySession.acceptLiveHypothesis("кукурузные хлопья любятово", owner: identityOwner, file: "identity.wav")
        require(identitySession.draft!.rows.isEmpty, "identity evidence does not invent a weight")
        try await identitySession.acceptLiveHypothesis("кукурузные хлопья любятого", owner: identityOwner, file: "identity.wav")
        try await identitySession.acceptLiveHypothesis("кукурузные хлопья любят 120 грамм", owner: identityOwner, file: "identity.wav")
        await identitySession.waitForLiveMatching()
        require(identitySession.draft!.rows.count == 1 && identitySession.draft!.rows[0].product?.id == cereal.id && identitySession.draft!.rows[0].amount == 120, "earlier brand reaches actual matching and row")
        let identityRowID = identitySession.draft!.rows[0].id
        identitySession.updateRow(identityRowID) { $0.quantity = "130" }
        try await identitySession.acceptLivePhrase("кукурузные хлопья любят 120 грамм", through: 553920, owner: identityOwner, file: "identity.wav", boundary: true)
        await identitySession.waitForLiveMatching()
        try await identitySession.flush()
        let identityReloaded = MealSession(store: identityStore, diagnosticLog: testLog)
        await identityReloaded.load()
        require(identityReloaded.draft!.rows.count == 1 && identityReloaded.draft!.rows[0].id == identityRowID && identityReloaded.draft!.rows[0].amount == 130 && identityReloaded.draft!.rows[0].product?.id == cereal.id, "final ASR and persisted row retain product manual grams and UUID")
        let searchRegressionStore = DiaryStore(container: try DiaryStore.makeContainer(url: editingDirectory.appendingPathComponent("search-regressions.store")), catalog: bundledCatalog)
        let bread = Product(id: "synthetic-bread", name: "Хлебцы мультизлаковые", brand: "Яндекс лавка", basis: .g, source: "synthetic")
        var breadDraft = ProductCreationDraft(product: bread)
        breadDraft.calories = "300"; breadDraft.protein = "10"; breadDraft.fat = "3"; breadDraft.carbs = "60"
        _ = try await searchRegressionStore.productRepository.commit(breadDraft)
        let breadResults = try await searchRegressionStore.rankedSearch("хлебцы мультизлаковые из лавки")
        require(breadResults.first?.id == bread.id, "token search finds bread despite a preposition and omitted brand word")
        let walnut = Product(id: "synthetic-walnut", name: "Грецкий орех", brand: "", basis: .g, source: "synthetic")
        var walnutDraft = ProductCreationDraft(product: walnut)
        walnutDraft.calories = "654"; walnutDraft.protein = "15.2"; walnutDraft.fat = "65.2"; walnutDraft.carbs = "7"
        _ = try await searchRegressionStore.productRepository.commit(walnutDraft)
        let stabilitySession = MealSession(store: searchRegressionStore, diagnosticLog: testLog)
        await stabilitySession.begin(day: searchRegressionStore.today)
        let stabilityOwner = stabilitySession.draft!.id
        stabilitySession.draft?.audioFile = "walnut.wav"
        stabilitySession.draft?.dictationID = UUID()
        try await stabilitySession.acceptLiveHypothesis("грецкий орех восемнадцать грамм", owner: stabilityOwner, file: "walnut.wav")
        require(stabilitySession.draft!.rows.first?.food == "грецкий орех", "exact walnut hypothesis creates the row")
        try await stabilitySession.acceptLiveHypothesis("gris period восемнадцать грамм", owner: stabilityOwner, file: "walnut.wav")
        require(stabilitySession.draft!.rows.count == 1 && stabilitySession.draft!.rows[0].food == "грецкий орех" && stabilitySession.draft!.rows[0].amount == 18,
                "later language switch cannot replace a catalogue-backed identity")
        await stabilitySession.waitForLiveMatching()
        let semanticStore = DiaryStore(container: try DiaryStore.makeContainer(url: editingDirectory.appendingPathComponent("semantic.store")), catalog: bundledCatalog)
        let semanticSession = MealSession(store: semanticStore, diagnosticLog: testLog)
        await semanticSession.begin(day: semanticStore.today)
        let semanticOwner = semanticSession.draft!.id
        semanticSession.draft?.audioFile = "semantic.wav"
        semanticSession.draft?.dictationID = UUID()
        try await semanticSession.acceptLiveHypothesis("молоко один процент", owner: semanticOwner, file: "semantic.wav")
        require(semanticSession.draft!.rows.isEmpty, "percent hypothesis does not create food")
        try await semanticSession.acceptLiveHypothesis("банан сто грамм", owner: semanticOwner, file: "semantic.wav")
        require(semanticSession.draft!.rows.count == 1, "complete hypothesis creates food without a pause")
        await semanticSession.waitForLiveMatching()
        require(semanticSession.draft!.rows[0].matchingPending != true, "matching runs before audio endpoint")
        let semanticID = semanticSession.draft!.rows[0].id
        try await semanticSession.acceptLiveHypothesis("банан сто пятьдесят грамм", owner: semanticOwner, file: "semantic.wav")
        require(semanticSession.draft!.rows[0].id == semanticID && semanticSession.draft!.rows[0].amount == 150, "revised ASR updates same row")
        semanticSession.updateRow(semanticID) { $0.quantity = "170" }
        try await semanticSession.acceptLiveHypothesis("банан двести грамм", owner: semanticOwner, file: "semantic.wav")
        require(semanticSession.draft!.rows[0].amount == 170, "ASR never overwrites manual weight")
        await semanticSession.waitForLiveMatching()
        try await semanticSession.flush()
        let semanticRecovered = MealSession(store: semanticStore, diagnosticLog: testLog)
        await semanticRecovered.load()
        try await semanticRecovered.acceptLivePhrase("банан двести грамм", through: 32000, owner: semanticOwner, file: "semantic.wav", boundary: true)
        require(semanticRecovered.draft!.rows.count == 1 && semanticRecovered.draft!.rows[0].id == semanticID && semanticRecovered.draft!.rows[0].amount == 170, "recovery and final ASR do not duplicate or overwrite")
        try await semanticRecovered.acceptLiveHypothesis("кукурузные хлопья любятово сто грамм", owner: semanticOwner, file: "semantic.wav")
        require(semanticRecovered.draft!.rows.count == 2, "cornflakes starts matching without silence")
        try await semanticRecovered.acceptLivePhrase("кукурузные хлопья любятово сто грамм ну вот я не понимаю", through: 64000, owner: semanticOwner, file: "semantic.wav", boundary: true)
        require(semanticRecovered.draft!.rows.count == 2 && semanticRecovered.draft!.rows.last?.amount == 100, "later complaint cannot erase or duplicate cornflakes")
        await semanticRecovered.waitForLiveMatching()
        let live = MealSession(store: liveStore, diagnosticLog: testLog,
            api: MealAPI(transport: { _ in fatalError("Live path must never call cloud") }))
        await live.begin(day: liveStore.today)
        let liveID = live.draft!.id
        live.draft?.audioFile = "synthetic-live.wav"
        live.draft?.liveMode = true
        live.draft?.dictationID = UUID()
        let staleLiveOperation = live.liveOperation(file: "synthetic-live.wav")!
        let emptySlotID = live.liveInputID
        live.showLiveText("бан")
        let previewID = live.liveProgress!.rows[0].id
        require(previewID == emptySlotID, "empty voice card becomes first hypothesis without changing identity")
        live.showLiveText("банан")
        require(live.liveProgress!.rows[0].id == previewID, "revised hypothesis keeps placeholder identity")
        require(live.draft!.rows.isEmpty, "hypothesis never contributes to nutrition or persistence")
        try await live.acceptLivePhrase("банан", through: 16000, owner: liveID, file: "synthetic-live.wav", boundary: true)
        require(live.draft!.rows.isEmpty && live.draft!.livePendingText == "банан", "pause preserves product")
        try await live.acceptLivePhrase("120 грамм", through: 32000, owner: liveID, file: "synthetic-live.wav", boundary: true)
        require(live.draft!.rows.count == 1 && live.draft!.rows[0].amount == 120, "pending product receives mass")
        require(live.draft!.rows[0].id == previewID, "accepted row keeps placeholder identity")
        try await live.acceptLiveHypothesis("хлеб 900 грамм", owner: liveID, file: "synthetic-live.wav", operation: staleLiveOperation)
        require(live.draft!.rows.count == 1 && live.draft!.rows[0].amount == 120, "old ASR revision cannot overwrite checkpointed speech")
        require(live.liveProgress?.rows.isEmpty == true, "accepted hypothesis clears placeholder")
        require(live.liveInputID != previewID, "accepted card gets a distinct next empty slot")
        live.parse()
        require(!live.busy, "live draft cannot start legacy cloud parser")
        await live.waitForLiveMatching()
        let recoveredLive = MealSession(store: liveStore, diagnosticLog: testLog)
        await recoveredLive.load()
        require(recoveredLive.draft?.liveAudioSampleOffset == 32000, "live cursor survives restart")
        try await recoveredLive.acceptLivePhrase("120 грамм", through: 32000, owner: liveID, file: "synthetic-live.wav", boundary: true)
        require(recoveredLive.draft?.rows.count == 1, "replayed audio does not duplicate meal")
        let rowID = recoveredLive.draft!.rows[0].id
        recoveredLive.updateRow(rowID) { $0.quantity = "130" }
        try await recoveredLive.acceptLivePhrase("помидоры 60 грамм", through: 48000, owner: liveID, file: "synthetic-live.wav", boundary: true)
        require(recoveredLive.draft?.rows.first?.amount == 130 && recoveredLive.draft?.rows.count == 2, "next phrase preserves manual edit")
        try await recoveredLive.acceptLivePhrase("хлеб 20 грамм", through: 64000, owner: UUID(), file: "synthetic-live.wav", boundary: true)
        require(recoveredLive.draft?.rows.count == 2, "stale draft result ignored")
        try FileManager.default.createDirectory(at: VoiceFiles.directory, withIntermediateDirectories: true)
        let liveAudio = VoiceFiles.url("synthetic-live.wav")
        defer { VoiceFiles.remove("synthetic-live.wav") }
        try Data(contentsOf: waveURL).write(to: liveAudio, options: .atomic)
        recoveredLive.draft?.livePendingText = "просто проверка"
        try await recoveredLive.finishLive(file: "synthetic-live.wav")
        require(recoveredLive.error == nil && recoveredLive.liveProgress == nil, "deactivating incomplete live input is silent")
        require(recoveredLive.draft?.audioFile == nil && recoveredLive.hasPendingDictation && !recoveredLive.canCommit,
            "finish archives audio and retains unresolved speech")
        let finalLive = MealSession(store: liveStore, diagnosticLog: testLog)
        await finalLive.load()
        require(finalLive.draft?.rows.count == 2 && finalLive.draft?.rows.first?.amount == 130, "final live rows survive restart")
        require(finalLive.draft?.livePendingText == "просто проверка", "unresolved speech survives restart")
        finalLive.resolvePendingSpeech(asFood: "Неизвестное блюдо")
        try await finalLive.flush()
        require(finalLive.draft?.rows.count == 3 && !finalLive.hasPendingDictation && finalLive.canCommit,
            "unresolved food can be confirmed without a card, weight or nutrition")
        let incompleteSummary = NutritionSummary(finalLive.draft!.rows.map(\.portion))
        require(incompleteSummary.missingCalories > 0, "unknown food stays unknown in totals")
        require(MealVoiceCommand.isStandalone("Удалить!") && MealVoiceCommand.isStandalone("СТОП."), "short command punctuation")
        require(!MealVoiceCommand.isStandalone("банан стоп") && !MealVoiceCommand.isStandalone("стопка"), "early command must be isolated")
        var commandEndpoint = LiveMealEndpoint()
        let commandAudio = Array(repeating: Float(0.04), count: 6_400) + Array(repeating: Float(0), count: 4_160)
        require(commandEndpoint.next(commandAudio, finished: false) == nil, "food endpoint still waits")
        require(commandEndpoint.commandRange != nil, "short command can be probed after 260ms silence")
        var commandClick = LiveMealEndpoint()
        _ = commandClick.next(Array(repeating: Float(0.04), count: 320) + Array(repeating: Float(0), count: 4_160), finished: false)
        require(commandClick.commandRange == nil, "click cannot trigger command probe")
        let commandsStore = DiaryStore(container: try DiaryStore.makeContainer(url: editingDirectory.appendingPathComponent("commands.store")), catalog: bundledCatalog)
        let commands = MealSession(store: commandsStore, diagnosticLog: testLog)
        await commands.begin(day: commandsStore.today)
        let commandOwner = commands.draft!.id
        commands.draft?.audioFile = "commands.wav"
        commands.draft?.liveMode = true
        try await commands.acceptLivePhrase("банан 100 грамм помидоры 60 грамм", through: 16000, owner: commandOwner, file: "commands.wav", boundary: true)
        require(commands.draft?.rows.count == 2, "command setup")
        try await commands.acceptLiveHypothesis("удалить", owner: commandOwner, file: "commands.wav")
        require(commands.draft?.rows.count == 2, "unstable command cannot delete")
        commands.draft?.livePendingText = "неоконченная фраза"
        try await commands.acceptLivePhrase("удалить банан 200 грамм", through: 32000, owner: commandOwner, file: "commands.wav", boundary: true)
        require(commands.draft?.rows.count == 2 && commands.draft?.rows.last?.amount == 200, "delete then fresh food in same phrase")
        require(commands.draft?.livePendingText == "", "delete clears pending input")
        try await commands.acceptLivePhrase("удалить банан 200 грамм", through: 32000, owner: commandOwner, file: "commands.wav", boundary: true)
        require(commands.draft?.rows.count == 2, "replayed command cannot delete again")
        let commandReload = MealSession(store: commandsStore, diagnosticLog: testLog)
        await commandReload.load()
        try await commandReload.acceptLivePhrase("удалить", through: 32000, owner: commandOwner, file: "commands.wav", boundary: true)
        require(commandReload.draft?.rows.count == 2, "command checkpoint survives restart")
        let stop = try await commands.acceptLivePhrase("стоп банан 900 грамм", through: 48000, owner: commandOwner, file: "commands.wav", boundary: true)
        require(stop && commands.draft?.rows.count == 2, "stop ignores following speech")
        try await commands.acceptLivePhrase("удалить удалить удалить", through: 64000, owner: commandOwner, file: "commands.wav", boundary: true)
        await commands.waitForLiveMatching()
        require(commands.draft?.rows.isEmpty == true, "empty delete safe and matching cannot resurrect rows")
        require(MealVoiceCommand.parts("стопка удалиться") == [.text("стопка удалиться")], "commands match whole words")

        let queueStore = DiaryStore(container: try DiaryStore.makeContainer(url: editingDirectory.appendingPathComponent("queue.store")), catalog: bundledCatalog)
        let queue = MealSession(store: queueStore, diagnosticLog: testLog)
        await queue.begin(day: queueStore.today)
        let queueOwner = queue.draft!.id
        queue.draft?.audioFile = "queue.wav"
        queue.draft?.dictationID = UUID()
        queue.draft?.liveMode = true
        var releaseMatch: CheckedContinuation<Void, Never>?
        queue.beforeLiveMatching = {
            await withCheckedContinuation { releaseMatch = $0 }
        }
        try await queue.acceptLivePhrase("банан 100 грамм", through: 16000, owner: queueOwner, file: "queue.wav", boundary: true)
        while releaseMatch == nil { await Task.yield() }
        queue.beforeLiveMatching = nil
        let firstQueuedID = queue.draft!.rows[0].id
        queue.showLiveText("огурец")
        require(queue.liveProgress?.rows.first?.food == "огурец" && queue.draft?.rows.first?.matchingPending == true, "next hypothesis visible while previous search blocked")
        try await queue.acceptLivePhrase("огурец 200 грамм", through: 32000, owner: queueOwner, file: "queue.wav", boundary: true)
        require(queue.draft?.rows.count == 2 && queue.draft?.rows.allSatisfy { $0.matchingPending == true } == true, "second pair accepted before first search finishes")
        let checkpoint = try await queue.repository.loadDraft()
        require(checkpoint?.rows.filter { $0.matchingPending == true }.count == 2 && checkpoint?.liveAudioSampleOffset == 32000, "pending queue checkpointed with cursor")
        queue.updateRow(firstQueuedID) { $0.quantity = "175" }
        let secondQueuedID = queue.draft!.rows[1].id
        queue.removeRows([secondQueuedID])
        queue.showLiveText("помидор")
        releaseMatch?.resume()
        await queue.waitForLiveMatching()
        require(queue.draft?.rows.count == 1 && queue.draft?.rows.first?.amount == 175, "async match preserves weight and never resurrects deleted row")
        require(queue.draft?.rows.first?.product != nil && queue.draft?.rows.first?.matchingPending != true, "queued match resolves real catalog product")
        require(queue.liveProgress?.rows.first?.food == "помидор", "old match cannot replace newer live text")
        // Simulate process restart from persisted pending work, no old worker remains.
        queue.draft?.rows[0].product = nil
        queue.draft?.rows[0].matchingPending = true
        queue.changed()
        try await queue.flush()
        let restoredQueue = MealSession(store: queueStore, diagnosticLog: testLog)
        await restoredQueue.load()
        await restoredQueue.waitForLiveMatching()
        require(restoredQueue.draft?.rows.first?.product != nil && restoredQueue.draft?.rows.first?.amount == 175, "pending lookup resumes after restart without losing weight")

        // Cancellation removes only rows belonging to this dictation, preserving earlier food.
        finalLive.draft?.audioFile = "synthetic-live.wav"
        finalLive.addManual(name: "Ранее добавленный продукт")
        try Data(contentsOf: waveURL).write(to: liveAudio, options: .atomic)
        require(finalLive.discardRecording(draftID: liveID, file: "synthetic-live.wav"), "live recording can be cancelled")
        try await finalLive.flush()
        require(finalLive.draft?.rows.count == 2 && finalLive.draft?.rows.map(\.food) == ["Неизвестное блюдо", "Ранее добавленный продукт"], "cancel preserves unrelated food")
        print("PASS: live phrase boundaries, quantities, pending slots, persisted audio cursor, replay and manual correction")

        let session = MealSession(store: store, diagnosticLog: testLog, api: api, keyProvider: { "synthetic-key" })
        await session.begin(day: store.today)
        session.draft?.transcript = "Синтетическая диктовка"; session.draft?.dictationPreviewOnly = false; session.changed()
        session.parse(); try await wait(session)
        require(session.error == nil, "parse: \(session.error ?? "")")
        require(session.draft?.rows.count == 3, "pipeline rows")
        require(session.draft?.pendingResponse == raw, "raw preserved")
        let persisted = try await session.repository.loadDraft()
        require(persisted?.rows.count == 3 && persisted?.pendingResponse == raw, "persisted response and rows")
        session.parse(); require(!session.busy && session.draft?.rows.count == 3, "no duplicate replay")
        session.error = nil; session.draft?.transcript = "Вторая синтетическая диктовка"; session.changed()
        session.parse()
        session.draft?.transcript = "Изменённый текст"; session.changed()
        try await wait(session)
        require(session.draft?.rows.count == 3, "stale result ignored")
        // An API failure retains text. Retrying with a key completes exactly once.
        let retryStore = DiaryStore(container: try DiaryStore.makeContainer(memory: true), catalog: Catalog(url: nil))
        let retry = MealSession(store: retryStore, diagnosticLog: testLog, api: api, keyProvider: { nil })
        await retry.begin(day: retryStore.today)
        retry.draft?.transcript = "Повторяемый текст"; retry.changed()
        retry.parse(); try await wait(retry)
        require(retry.error != nil && retry.hasPendingDictation && retry.draft?.rows.isEmpty == true, "failure retains input")
        retry.parse(key: "synthetic-key"); try await wait(retry)
        require(retry.error == nil && retry.draft?.rows.count == 3, "retry succeeds")
        let savedStore = DiaryStore(container: try DiaryStore.makeContainer(memory: true), catalog: Catalog(url: nil))
        let saved = MealSession(store: savedStore, diagnosticLog: testLog, api: MealAPI(transport: { _ in fatalError("Saved response must not trigger API") }), keyProvider: { fatalError("Saved response needs no key") })
        await saved.begin(day: savedStore.today)
        saved.draft?.transcript = "Синтетический сохранённый текст"
        saved.draft?.pendingResponse = "Молоко|250 грамм\nЯйца|119 грамм\nТворог|200 грамм"
        saved.changed(); saved.parse(reuseSavedResponse: true); try await wait(saved)
        require(saved.error == nil && saved.draft?.rows.count == 3 && !saved.hasPendingDictation, "saved response recovery")
        saved.parse(reuseSavedResponse: true); require(saved.draft?.rows.count == 3 && !saved.busy, "saved response once")
        let failedAPI = MealAPI(transport: { _ in throw URLError(.notConnectedToInternet) })
        let failedStore = DiaryStore(container: try DiaryStore.makeContainer(memory: true), catalog: Catalog(url: nil))
        let failed = MealSession(store: failedStore, diagnosticLog: testLog, api: failedAPI, keyProvider: { "synthetic-key" })
        await failed.begin(day: failedStore.today)
        failed.draft?.transcript = "Сеть недоступна"; failed.changed(); failed.parse(); try await wait(failed)
        require(failed.error != nil && failed.draft?.transcript == "Сеть недоступна" && failed.hasPendingDictation, "network recovery")
        retry.draft?.transcript = "Закрываем во время запроса"; retry.changed(); retry.parse(key: "synthetic-key")
        await retry.close(); try await wait(retry)
        require(retry.draft?.rows.count == 3 && !retry.showing && retry.hasPendingDictation, "cancel preserves pending text")
        let curd = Product(id: "curd", name: "Творог", brand: "", basis: .g, source: "synthetic-test")
        let options = MealMatcher.rank("Творог, который купил вчера", products: [curd], history: [])
        require(options.count == 1 && MealMatcher.suggestion(options) == nil, "unresolved temporal reference is not an automatic match")
        require(MealMatcher.searchPhrase("Салат цезарь от ВкусВилла") == "салат цезарь вкусвилла", "producer query")
        require(MealMatcher.words("гречки курицы бананов яйцами") == MealMatcher.words("гречка курица банан яйца"), "Russian inflections")
        require(MealMatcher.searchWords("и но что банан огурец помидор сыр мясо груша яблоко творог молоко перец").count == 10, "all significant words, no eight-word cutoff")
        let milkA = Product(id: "milkA", name: "Молоко 2,5%", brand: "", basis: .g, source: "synthetic-test")
        let milkB = Product(id: "milkB", name: "Молоко 5,2%", brand: "", basis: .g, source: "synthetic-test")
        require(MealMatcher.suggestion(MealMatcher.rank("молоко 2.5%", products: [milkB, milkA], history: []))?.id == "milkA", "decimal identity is not reordered")
        let duplicate = Product(id: "secondBanana", name: banana.name, brand: "", basis: .g, source: "synthetic-test")
        require(MealMatcher.suggestion(MealMatcher.rank("банан", products: [banana, duplicate], history: [])) == nil, "close scores require attention")
        let coldStore = DiaryStore(container: try DiaryStore.makeContainer(memory: true), catalog: bundledCatalog)
        let cold = MealSession(store: coldStore, diagnosticLog: testLog)
        await cold.begin(day: coldStore.today)
        cold.draft?.transcript = banana.name + " 100 и абракадабра 20"
        cold.draft?.pendingResponse = banana.name + "|100\nабракадабра|20"
        cold.changed(); cold.parse(reuseSavedResponse: true); try await wait(cold)
        require(cold.error == nil, "cold full catalog pipeline")
        require(cold.sortedRows.first?.food == "абракадабра" && cold.sortedRows.first?.requiresAttention == true, "attention rows first")
        require(cold.sortedRows.last?.product?.id == banana.id && cold.sortedRows.last?.requiresAttention == false, "full product name matched without history")
        let known = cold.sortedRows.last!
        require(known.matchContextIDs?.contains(banana.id) == true, "context provenance retained")
        cold.choose(duplicate, for: known.id)
        try await cold.flush()
        let reopened = try await cold.repository.loadDraft()
        require(reopened?.rows.first?.matchOptions?.isEmpty == false, "ranked candidates survive draft reopen")
        cold.log("explicitTrace", fields: ["traceID": "preserved-trace"])
        cold.updateRow(known.id) { $0.quantity = "123.5" }
        let unknownIDs = Set(cold.draft!.rows.filter { $0.id != known.id }.map(\.id))
        cold.removeRows(unknownIDs)
        try await cold.flush()
        try await testLog.write("barrier", fields: [:])
        let events = try await testLog.events()
        require(!events.isEmpty, "diagnostic records written")
        require(events.contains { $0["event"] == "choice" && $0["after"] == duplicate.id && $0["inContext"] == "false" }, "manual correction outside context logged")
        require(events.contains { $0["event"] == "explicitTrace" && $0["traceID"] == "preserved-trace" }, "explicit correlation survives logger")
        require(events.contains { $0["event"] == "rowEdited" && $0["after"]?.contains("123.5") == true && $0["before"] != $0["after"] }, "weight correction keeps before/after")
        require(events.contains { $0["event"] == "rowDeleted" && $0["before"] != nil }, "deleted proposal retained")
        for index in 0..<250 { cold.log("burstAudit", fields: ["index": String(index)]) }
        try await cold.flushLog()
        let burstEvents = try await testLog.events().filter { $0["event"] == "burstAudit" }
        require(burstEvents.count == 250 && Set(burstEvents.compactMap { $0["index"] }).count == 250,
                "one log worker drains a burst without losing or duplicating events")
        let failedDirectory = logDirectory.appendingPathComponent("retry")
        try Data("synthetic blockage".utf8).write(to: failedDirectory)
        let retryLog = MatchingLog(directory: failedDirectory)
        let retrySession = MealSession(store: coldStore, diagnosticLog: retryLog)
        retrySession.log("retainedAfterFailure", fields: ["traceID": "retry-trace"])
        do { try await retrySession.flushLog(); fatalError("Expected archive write failure") } catch {}
        require(retrySession.diagnosticError != nil, "archive failure is visible")
        try FileManager.default.removeItem(at: failedDirectory)
        try await retrySession.flushLog()
        let recoveredEvents = try await retryLog.events()
        require(recoveredEvents.count == 1 && retrySession.diagnosticError == nil, "failed queue drains after retry without duplicates")
        let outboxContainer = try DiaryStore.makeContainer(memory: true)
        let outboxStore = DiaryStore(container: outboxContainer, catalog: bundledCatalog)
        var outboxDraft = MealDraft(day: outboxStore.today, meal: .breakfast)
        let outboxEventID = UUID().uuidString
        outboxDraft.auditPending = [MealArchiveEvent(name: "rowEditedRecovered", fields: ["eventID": outboxEventID, "draftID": outboxDraft.id.uuidString])]
        try await MealRepository(container: outboxContainer).persist(outboxDraft)
        let outboxSession = MealSession(store: outboxStore, diagnosticLog: testLog)
        await outboxSession.load(); try await outboxSession.flush()
        let outboxEvents = try await testLog.events()
        require(outboxEvents.contains { $0["eventID"] == outboxEventID }, "persisted outbox replayed after load")
        let clearedOutbox = try await outboxSession.repository.loadDraft()
        require(clearedOutbox?.auditPending == nil, "outbox removed only after archive flush")
        let requestAudit = MatchingLog(directory: logDirectory.appendingPathComponent("http"))
        let badAPI = MealAPI(transport: { request in
            (Data("{\"choices\":[]}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await badAPI.extract("синтетический текст", key: "do-not-log-this-key") { event, fields in
                try await requestAudit.write(event, fields: fields)
            }
            fatalError("Expected malformed response")
        } catch {}
        let httpText = try await requestAudit.events().map { String(describing: $0) }.joined()
        require(httpText.contains("modelHTTPResponse") && httpText.contains("modelRequest"), "raw invalid HTTP response and request archived")
        require(!httpText.contains("do-not-log-this-key"), "authorization key excluded from archive")
        let audioID = UUID(), audioSource = logDirectory.appendingPathComponent("synthetic.wav")
        let audioBytes = Data("synthetic audio bytes".utf8)
        try audioBytes.write(to: audioSource)
        let archivedAudio = try await testLog.archiveAudio(audioSource, dictationID: audioID)
        _ = try await testLog.archiveAudio(audioSource, dictationID: audioID)
        let archivedBytes = try Data(contentsOf: logDirectory.appendingPathComponent(archivedAudio["audio"]!))
        require(archivedBytes == audioBytes && archivedAudio["audioSHA256"]?.count == 64, "audio exact copy with hash; idempotent retry")
        let oversized = logDirectory.appendingPathComponent("000-large.json")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 33 * 1024 * 1024); try handle.close()
        try await testLog.write("sizeLimit", fields: [:])
        require(FileManager.default.fileExists(atPath: oversized.path), "archive does not silently prune at 32 MiB")
        let oldFile = logDirectory.appendingPathComponent("old.json")
        try Data("{}".utf8).write(to: oldFile)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: oldFile.path)
        try await testLog.write("retention", fields: [:])
        require(FileManager.default.fileExists(atPath: oldFile.path), "archive has no 30-day expiry")
        let cancelStore = DiaryStore(container: try DiaryStore.makeContainer(memory: true), catalog: bundledCatalog)
        let cancelled = MealSession(store: cancelStore, diagnosticLog: testLog,
            api: MealAPI(transport: { _ in fatalError("Cancellation must not call the model") }))
        await cancelled.begin(day: cancelStore.today)
        cancelled.addManual(banana)
        cancelled.updateRow(cancelled.draft!.rows[0].id) { $0.quantity = "110" }
        let rowsBeforeCancel = cancelled.draft!.rows
        let clip = try VoiceFiles.create()
        try Data("synthetic cancelled audio".utf8).write(to: VoiceFiles.url(clip))
        defer { VoiceFiles.remove(clip) }
        cancelled.draft?.audioFile = clip
        cancelled.draft?.transcript = ""
        cancelled.draft?.dictationPreviewOnly = true
        cancelled.changed(); try await cancelled.flush()
        require(!cancelled.discardRecording(draftID: UUID(), file: clip), "stale owner cannot cancel current recording")
        require(!cancelled.discardRecording(draftID: cancelled.draft!.id, file: "old.wav"), "stale file cannot cancel current recording")
        require(cancelled.discardRecording(draftID: cancelled.draft!.id, file: clip), "cancel active clip")
        require(cancelled.draft?.rows == rowsBeforeCancel && !cancelled.hasPendingDictation && cancelled.canCommit, "cancel preserves rows and permits save/new dictation")
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: VoiceFiles.url(clip).path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        require(!FileManager.default.fileExists(atPath: VoiceFiles.url(clip).path), "cancelled audio removed after persistence")
        let cancelledDisk = try await cancelled.repository.loadDraft()
        require(cancelledDisk?.audioFile == nil && cancelledDisk?.rows == rowsBeforeCancel, "cancel survives draft reopen")
        let indexingStart = Date()
        let preparedIndex = SearchIndex(products: basicFoods)
        let indexingMS = Date().timeIntervalSince(indexingStart) * 1000
        var timings: [Double] = []
        for _ in 0..<10 {
            let start = Date()
            for query in ["банан", "огурец", "курица", "гречка", "творог", "яблоко", "хлеб", "молоко", "яйца", "абракадабра"] {
                _ = preparedIndex.rank(query, history: [])
            }
            timings.append(Date().timeIntervalSince(start) * 1000)
        }
        print("Matching benchmark Mac: index \(indexingMS) ms; 10 queries median \(timings.sorted()[5]) ms; max \(timings.max()!) ms")
        print("PASS: compact/legacy output, decimals, invalid responses, request, real SwiftData persistence, duplicate/stale protection, failure/retry")
    }
}
