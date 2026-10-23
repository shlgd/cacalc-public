import XCTest
@testable import Cacalc

/// Opt-in device checks: weights and synthetic audio must be staged locally first.
/// Ordinary simulator tests never download or run inference.
@MainActor final class VoiceModelTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["CACALC_RUN_MODEL_TESTS"] == "1" else {
            throw XCTSkip("Модельные серии запускаются отдельно: CACALC_RUN_MODEL_TESTS=1")
        }
    }
    private func engine() async throws -> VoiceEngine {
        #if targetEnvironment(simulator)
        throw XCTSkip("Проверка MLX требует физического iPhone")
        #else
        let assets = VoiceAssets()
        guard try await assets.isReady() else { throw XCTSkip("Голосовые модели не подготовлены") }
        return VoiceEngine(assets: assets)
        #endif
    }
    func testCandidateQwenConversationalJSON() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Проверка MLX требует физического iPhone")
        #else
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceModelCandidates/qwen4b")
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.safetensors").path) else {
            throw XCTSkip("Веса кандидата не подготовлены")
        }
        let candidate = VoiceEngine(assets: VoiceAssets(), languageModelDirectory: directory)
        try await checkConversationalJSON(candidate)
        #endif
    }
    func testLocalQwenConversationalJSON() async throws {
        try await checkConversationalJSON(engine())
    }
    /// Two short passes only; use this separately from the long model suite.
    func testLocalQwenBrandAndPrefixCache() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Проверка MLX требует физического iPhone")
        #else
        let assets = VoiceAssets()
        guard try await assets.isReady() else { throw XCTSkip("Голосовые модели не подготовлены") }
        let directory = try await assets.directory("qwen")
        let manifest = try VoiceManifest.bundled()
        let revision = try XCTUnwrap(manifest.models.first { $0.id == "qwen" }).revision
        // Invented nutrition: this checks extraction, not a real label.
        let phrase = "Тунец Лента в собственном соку. На сто граммов белки двадцать три, жиры полтора, углеводы ноль, калории сто десять."
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var previous: Data?
        for index in 0..<2 {
            let start = ContinuousClock.now
            let result = try await VoiceLanguageModel.extract(phrase, system: VoiceEngine.prompt(),
                modelDirectory: directory, modelRevision: revision, cacheDirectory: VoicePromptCache.directory)
            let value = result.extraction
            let json = try encoder.encode(value)
            print("CACALC_PREFIX_CACHE_\(index): \(start.duration(to: .now)); load=\(result.loadSeconds); inference=\(result.generationSeconds); hit=\(result.cacheHit); prefix=\(result.cachedTokens); " + String(decoding: json, as: UTF8.self))
            XCTAssertEqual(value.brand, "Лента")
            XCTAssertFalse(value.name.localizedCaseInsensitiveContains("Лента"))
            XCTAssertEqual(value.protein, Decimal(23)); XCTAssertEqual(value.fat, Decimal(string: "1.5"))
            XCTAssertEqual(value.carbs, Decimal(0)); XCTAssertEqual(value.calories, Decimal(110))
            XCTAssertEqual(value.basis, "g"); XCTAssertNil(value.manufacturer)
            XCTAssertGreaterThan(result.cachedTokens, 0)
            if let previous { XCTAssertEqual(json, previous); XCTAssertTrue(result.cacheHit) }
            previous = json
        }
        #endif
    }
    private func checkConversationalJSON(_ engine: VoiceEngine) async throws {
        let cases: [(String, String, String, String)] = [
            ("Тестовый йогурт на сто граммов. Белков пять и восемь, жира один сорок два, углеводов ноль ноль пять.", "5.8", "1.42", "0.05"),
            ("Это тестовый творог на сто грамм. Белков пять, нет, белков пять и восемь. Жиров полграмма, углеводов семь.", "5.8", "0.5", "7"),
            ("Тестовый продукт на 100 граммов. Жиров семь, нет, это углеводов семь. Жиров полграмма. Белков три.", "3", "0.5", "7"),
            ("Тестовый напиток на 100 мл. Белки 2,9, жиры 1,5, углеводы 4,9, энергия 209 кДж.", "2.9", "1.5", "4.9")
        ]
        for (phrase, protein, fat, carbs) in cases {
            var draft = ProductCreationDraft(); draft.transcript = phrase
            let start = ContinuousClock.now
            let extraction = try await engine.extract(phrase)
            draft = extraction.applying(to: draft)
            print("CACALC_FLAT_JSON: \(start.duration(to: .now)); " + String(decoding: try JSONEncoder().encode(extraction), as: UTF8.self))
            XCTAssertEqual(draft.protein, protein); XCTAssertEqual(draft.fat, fat); XCTAssertEqual(draft.carbs, carbs)
            XCTAssertTrue(draft.calories.isEmpty); XCTAssertTrue(draft.notices.isEmpty)
            XCTAssertFalse(draft.name.isEmpty)
        }
    }
    func testLocalQwenNumbersBeforeNutrients() async throws {
        let engine = try await engine()
        let phrases = [
            "Тестовый йогурт. На сто граммов, 5 запятая, 8 грамм белков, 0 запятая,5 грамм жиров, 12 грамм углеводов.",
            "Тестовый йогурт на сто граммов: пять запятая, восемь граммов белка, ноль точка. пять грамма жира, двенадцать граммов углеводов.",
            "Тестовый йогурт на 100 г, 5,8 г белка, 0 запятая,05 г жира, 12 г углеводов."
        ]
        for (index, phrase) in phrases.enumerated() {
            var draft = ProductCreationDraft(); draft.transcript = phrase
            let start = ContinuousClock.now
            let extraction = try await engine.extract(phrase)
            print("CACALC_DECIMAL_REGRESSION_JSON: " + String(decoding: try JSONEncoder().encode(extraction), as: UTF8.self))
            draft = extraction.applying(to: draft)
            print("CACALC_DECIMAL_REGRESSION_\(index): \(start.duration(to: .now)); P=\(draft.protein) F=\(draft.fat) C=\(draft.carbs); notices=\(draft.notices)")
            XCTAssertEqual(draft.protein, "5.8")
            XCTAssertEqual(draft.fat, index == 2 ? "0.05" : "0.5")
            XCTAssertEqual(draft.carbs, "12"); XCTAssertTrue(draft.calories.isEmpty)
            XCTAssertTrue(draft.notices.isEmpty); XCTAssertEqual(draft.basis, .g)
            XCTAssertFalse(draft.name.isEmpty)
        }
    }
    func testLocalQwenRussianDecimals() async throws {
        let engine = try await engine()
        let phrases = [
            "Молоко Простоквашино. На сто миллилитров 45 килокалорий, белка 2,9, жира 1.5, углеводов 4,9.",
            "Молоко Простоквашино на сто миллилитров. Белка две целых девять десятых, жира одна целая пять десятых, углеводов четыре целых девять десятых. Калорий сорок пять.",
            "Молоко Простоквашино на 100 мл: жиры один запятая пять, углеводы четыре точка девять, белки два запятая девять, 45 ккал.",
            "Сыр тестовый на сто граммов. Белки двадцать пять, жиры ноль целых пять сотых, углеводы ноль."
        ]
        for (index, phrase) in phrases.enumerated() {
            var d = ProductCreationDraft(); d.transcript = phrase
            let start = ContinuousClock.now
            let extraction = try await engine.extract(phrase)
            print("CACALC_SYNTHETIC_JSON: " + String(decoding: try JSONEncoder().encode(extraction), as: UTF8.self))
            d = extraction.applying(to: d)
            print("CACALC_MODEL_CASE_\(index): \(start.duration(to: .now)); P=\(d.protein) F=\(d.fat) C=\(d.carbs) K=\(d.calories); notices=\(d.notices)")
            XCTAssertTrue(d.notices.isEmpty)
            if index < 3 {
                XCTAssertEqual(d.protein, "2.9"); XCTAssertEqual(d.fat, "1.5"); XCTAssertEqual(d.carbs, "4.9")
                XCTAssertEqual(d.calories, "45"); XCTAssertEqual(d.basis, .ml)
            } else {
                XCTAssertEqual(d.protein, "25"); XCTAssertEqual(d.fat, "0.05"); XCTAssertEqual(d.carbs, "0")
                XCTAssertTrue(d.calories.isEmpty)
            }
            XCTAssertFalse(d.name.isEmpty)
            XCTAssertTrue(d.manufacturer.isEmpty)
        }
    }
    func testLocalParakeetToQwenSyntheticAudio() async throws {
        let engine = try await engine()
        let input = VoiceFiles.directory.deletingLastPathComponent().appendingPathComponent("VoiceTestInput/milk.wav")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("Синтетическое аудио не подготовлено") }
        let preparation = ContinuousClock.now
        try await engine.prepareSpeech()
        print("CACALC_SYNTHETIC_PREWARM: \(preparation.duration(to: .now))")
        let start = ContinuousClock.now
        let transcript = try await engine.transcribe(input)
        print("CACALC_SYNTHETIC_ASR: \(start.duration(to: .now)); \(transcript)")
        var draft = ProductCreationDraft(); draft.transcript = transcript
        draft = try await engine.extract(transcript).applying(to: draft)
        print("CACALC_SYNTHETIC_PIPELINE: \(start.duration(to: .now)); \(draft.name); \(draft.notices)")
        XCTAssertEqual(draft.protein, "2.9"); XCTAssertEqual(draft.fat, "1.5"); XCTAssertEqual(draft.carbs, "4.9")
        XCTAssertEqual(draft.calories, "45"); XCTAssertEqual(draft.basis, .ml)
    }
}
