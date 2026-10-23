import XCTest
@testable import Cacalc

@MainActor final class LabelParserTests: XCTestCase {
    func testDecimalsCorrectionsAndLabelOrder() throws {
        let parsed = try RussianLabelParser.parse("На сто миллилитров. 5 запятая, 8 грамм белков. Жиров один сорок два, нет, ноль ноль пять. Углеводов три и один. 45 ккал.")
        XCTAssertEqual(parsed.values[.protein], Decimal(string: "5.8"))
        XCTAssertEqual(parsed.values[.fat], Decimal(string: "0.05"))
        XCTAssertEqual(parsed.values[.carbs], Decimal(string: "3.1"))
        XCTAssertEqual(parsed.values[.calories], 45)
        XCTAssertEqual(parsed.basis, .ml)
    }
    func testPartialResultPreservesExistingFieldsAndExactDecimals() throws {
        var original = ProductCreationDraft()
        original.name = "Синтетический продукт"; original.brand = "Тестовая марка"
        original.protein = "16.25"; original.fat = "0,5"; original.calories = "95.5"
        let parsed = try RussianLabelParser.parse("Углеводов 0,123456789123456789. Белки не помню.")
        let updated = parsed.applying(to: original)
        XCTAssertEqual(updated.name, original.name); XCTAssertEqual(updated.brand, original.brand)
        XCTAssertEqual(updated.protein, original.protein); XCTAssertEqual(updated.fat, original.fat)
        XCTAssertEqual(updated.calories, original.calories); XCTAssertEqual(updated.carbs, "0.123456789123456789")
        XCTAssertFalse(updated.notices.isEmpty)
        let restored = try JSONDecoder().decode(ProductCreationDraft.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(restored, updated)
    }
    func testAmbiguityWrongBasisAndUnitsDoNotBecomeNutrition() throws {
        for text in ["На порцию 150 г белков 8, жиров 6, углеводов 20, 166 ккал.",
                     "На 100 г белки 8. На 100 мл жиры 6.",
                     "Белков пять. Белков восемь.", "Калории 209 кДж.", "Жирность 45 процентов."] {
            let result = try RussianLabelParser.parse(text)
            XCTAssertTrue(result.values.isEmpty, text)
        }
        var original = ProductCreationDraft(); original.calories = "45"; original.protein = "3"
        let updated = try RussianLabelParser.parse("На сто мл жиров один.").applying(to: original)
        XCTAssertEqual(updated.basis, .g); XCTAssertTrue(updated.fat.isEmpty)
        XCTAssertEqual(updated.protein, "3"); XCTAssertFalse(updated.notices.isEmpty)
    }
    func testExplicitIdentityAndZeroDoNotInventMissingCalories() throws {
        let result = try RussianLabelParser.parse("Название тунец в собственном соку. Марка Пример. Белков 24, жиров 1, углеводов ноль.")
        let draft = result.applying(to: ProductCreationDraft())
        XCTAssertEqual(draft.name, "тунец в собственном соку"); XCTAssertEqual(draft.brand, "Пример")
        XCTAssertNil(try draft.product().calories); XCTAssertEqual(try draft.product().carbs, 0)
        XCTAssertThrowsError(try draft.product().portion(100, unit: .g))
    }
    func testSavedTranscriptCompletesWithoutAnyModels() async throws {
        let library = ProductLibrary(container: try DiaryStore.makeContainer(memory: true))
        await library.begin()
        library.draft?.transcript = "Название синтетический йогурт. Белков пять и восемь. Жиров ноль пять. Углеводов три."
        library.draft?.voiceStage = .transcribed
        try await library.flush()
        let voice = VoiceSession()
        voice.transcribe(library)
        let deadline = ContinuousClock.now + .seconds(3)
        while voice.processing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(voice.processing); XCTAssertFalse(voice.needsModels); XCTAssertNil(voice.error)
        XCTAssertEqual(library.draft?.voiceStage, .applied)
        XCTAssertEqual(library.draft?.protein, "5.8"); XCTAssertEqual(library.draft?.fat, "0.5")
        let saved = try await library.repository.loadDraft()
        XCTAssertEqual(saved, library.draft)
        XCTAssertTrue(library.showingEditor, "Поля требуют подтверждения пользователя")
    }
    func testSpeechAssetsCanBeReadyWithoutQwen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = String(repeating: "a", count: 40)
        let file = VoiceManifest.Model.File(path: "synthetic.bin", bytes: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let manifest = VoiceManifest(version: 1, models: [
            .init(id: "parakeet", repository: "synthetic/asr", revision: revision, files: [file]),
            .init(id: "qwen", repository: "synthetic/llm", revision: revision, files: [file])
        ])
        let directory = root.appendingPathComponent("parakeet-" + revision)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: directory.appendingPathComponent(file.path))
        let assets = VoiceAssets(root: root, manifest: manifest)
        let speech = try await assets.isReady(models: ["parakeet"])
        let all = try await assets.isReady()
        let speechDirectory = try await assets.directory("parakeet")
        XCTAssertTrue(speech); XCTAssertFalse(all); XCTAssertEqual(speechDirectory.path, directory.path)
        do { _ = try await assets.directory("qwen"); XCTFail("Отсутствующие веса не готовы") } catch {}
    }
}
