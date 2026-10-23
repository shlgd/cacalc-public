import XCTest
import SwiftData
@testable import Cacalc

@MainActor final class VoiceProductTests: XCTestCase {
    // Synthetic dictations, never data copied from a personal diary.
    func draft() -> ProductCreationDraft {
        var d = ProductCreationDraft()
        d.name = "Тестовое молоко"; d.brand = "Синтетический бренд"; d.basis = .ml
        d.calories = "45"; d.protein = "2,9"; d.fat = "1.5"; d.carbs = "4,9"
        return d
    }
    func extraction(_ fields: String) throws -> ProductExtraction {
        try ProductExtraction.decode("{\"name\":\"Тестовый продукт\"," + fields + "}")
    }
    func testFlatJSONPreservesDecimalsAndUnknownValues() throws {
        let result = try extraction("\"protein\":5.8,\"fat\":0.05,\"carbs\":0.123456789123456789,\"calories\":null,\"basis\":\"ml\"")
            .applying(to: ProductCreationDraft())
        XCTAssertEqual(result.protein, "5.8"); XCTAssertEqual(result.fat, "0.05")
        XCTAssertEqual(result.carbs, "0.123456789123456789"); XCTAssertTrue(result.calories.isEmpty)
        XCTAssertEqual(result.basis, .ml); XCTAssertTrue(result.notices.isEmpty)
        XCTAssertNil(try result.product().calories)
        XCTAssertThrowsError(try result.product().portion(100, unit: .ml))
        let zero = try extraction("\"protein\":0,\"fat\":0,\"carbs\":0").applying(to: ProductCreationDraft())
        XCTAssertEqual(zero.protein, "0"); XCTAssertEqual(zero.fat, "0"); XCTAssertEqual(zero.carbs, "0")
    }
    func testModelInterpretationIsNotOverriddenByWordOrder() throws {
        for phrase in [
            "Пять запятая, восемь грамм белков. Жиров ноль запятая, пять, углеводов один сорок два.",
            "Белков пять и восемь, жиров ноль пять, углеводов один сорок два.",
            "Белков пять, нет, белков пять и восемь. Жиров полграмма, углеводов один сорок два.",
            "По белку тут получается, сейчас посмотрю, пять и восемь. Жиров полграмма. Углеводы — один сорок два."
        ] {
            var original = ProductCreationDraft(); original.transcript = phrase
            let result = try extraction("\"protein\":5.8,\"fat\":0.5,\"carbs\":1.42").applying(to: original)
            XCTAssertEqual(result.protein, "5.8"); XCTAssertEqual(result.fat, "0.5"); XCTAssertEqual(result.carbs, "1.42")
            XCTAssertEqual(result.transcript, phrase); XCTAssertTrue(result.notices.isEmpty)
        }
    }
    func testSchemaRejectsWrongTypesRangesAndUnexpectedFields() throws {
        for output in [
            "[]", "null", "{}", "{\"name\":12}", "{\"name\":null}",
            "{\"name\":\"Тест\",\"protein\":\"5.8\"}",
            "{\"name\":\"Тест\",\"protein\":true}",
            "{\"name\":\"Тест\",\"fat\":false}",
            "{\"name\":\"Тест\",\"protein\":{\"value\":5.8}}",
            "{\"name\":\"Тест\",\"brand\":3}",
            "{\"name\":\"Тест\",\"manufacturer\":[\"Пример\"]}",
            "{\"name\":\"Тест\",\"basis\":\"kg\"}",
            "{\"name\":\"Тест\",\"protein\":-0.5}",
            "{\"name\":\"Тест\",\"calories\":1000001}",
            "{\"name\":\"Тест\",\"fat\":0.0000000000000000001}",
            "{\"name\":\"Тест\",\"carbs\":NaN}",
            "{\"name\":\"Тест\",\"weight\":100}",
            "Ответ: {\"name\":\"Тест\"}"
        ] {
            XCTAssertThrowsError(try ProductExtraction.decode(output), output)
        }
        let tooLong = "{\"name\":\"" + String(repeating: "а", count: 201) + "\"}"
        XCTAssertThrowsError(try ProductExtraction.decode(tooLong))
    }
    func testOptionalFieldsKeepDraftAndValidResponseClearsObsoleteNotices() throws {
        var original = draft(); original.transcript = "Исправляю белки на семь и три"
        original.notices = ["Старая ошибка разбора"]
        let updated = try ProductExtraction.decode("{\"name\":\"\",\"protein\":7.3,\"fat\":null}").applying(to: original)
        XCTAssertEqual(updated.name, original.name); XCTAssertEqual(updated.brand, original.brand)
        XCTAssertEqual(updated.protein, "7.3"); XCTAssertEqual(updated.fat, original.fat)
        XCTAssertEqual(updated.calories, original.calories); XCTAssertTrue(updated.notices.isEmpty)
        let fenced = try ProductExtraction.decode("```json\n{\"name\":\"Тест\",\"fat\":0.5}\n```")
        XCTAssertEqual(fenced.fat, Decimal(string: "0.5"))
    }
    func testPromptAndSchemaAreBundledTogether() throws {
        let prompt = try VoiceEngine.prompt()
        XCTAssertTrue(prompt.contains("protein")); XCTAssertTrue(prompt.contains("1.42"))
        let url = try XCTUnwrap(Bundle.main.url(forResource: "product-extraction-schema", withExtension: "json"))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["name", "brand", "manufacturer", "basis", "calories", "protein", "fat", "carbs"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }
    func testPromptPrefixNeverIncludesUserTokensAndInvalidatesAcrossModels() {
        let system = Array(0..<800), full = Array(0..<800) + [9999, 12345]
        let prefix = VoicePromptPrefix.tokens(system: system, full: full)
        XCTAssertEqual(prefix, Array(0..<768))
        XCTAssertEqual(VoicePromptPrefix.tokens(system: system, full: system + [42]), prefix)
        XCTAssertTrue(VoicePromptPrefix.tokens(system: [1, 2, 3], full: [1, 2, 4, 99]).isEmpty)
        XCTAssertTrue(VoicePromptPrefix.tokens(system: [1, 2], full: [1, 2, 999]).isEmpty)
        XCTAssertNotEqual(VoicePromptPrefix.identity(model: "revision-a", tokens: prefix),
                          VoicePromptPrefix.identity(model: "revision-b", tokens: prefix))
        XCTAssertNotEqual(VoicePromptPrefix.identity(model: "revision-a", tokens: prefix),
                          VoicePromptPrefix.identity(model: "revision-a", tokens: prefix + [7]))
    }
    func testIndependentSaveRecoveryAndHistorySnapshot() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("test.store")
        let container = try DiaryStore.makeContainer(url: location)
        let repository = ProductRepository(container: container)
        var d = draft(); d.transcript = "Синтетическая диктовка"; d.audioFile = "synthetic.wav"
        d.voiceStage = .transcribed
        try await repository.persist(d)
        let restored = try await ProductRepository(container: DiaryStore.makeContainer(url: location)).loadDraft()
        XCTAssertEqual(restored, d)
        let product = try await repository.commit(d)
        let store = DiaryStore(container: container, catalog: Catalog(url: nil))
        XCTAssertTrue(store.items.isEmpty)
        let found = try await store.search("Синтетический бренд")
        XCTAssertEqual(found.first?.id, product.id)
        try store.persistDraft(FoodDraft(day: store.today, meal: .lunch, product: product, quantity: "150,5", basis: .ml))
        try store.commitDraft()
        var edited = ProductCreationDraft(product: product); edited.protein = "9.7"; edited.name = "Изменённое молоко"
        _ = try await repository.commit(edited)
        try store.reload()
        XCTAssertEqual(store.items.first?.product?.protein, Decimal(string: "2.9"))
        XCTAssertEqual(store.items.first?.total.protein, Decimal(string: "4.3645"))
        let reopened = try DiaryStore.makeContainer(url: location)
        let next = try await ProductRepository(container: reopened).search("Изменённое")
        XCTAssertEqual(next.first?.protein, Decimal(string: "9.7"))
        let emptyDraft = try await ProductRepository(container: reopened).loadDraft()
        XCTAssertNil(emptyDraft)
    }
    func testVoiceRecoveryStagesAndLegacyDraft() throws {
        var d = draft(); d.audioFile = "synthetic.wav"
        let oldData = try JSONEncoder().encode(d)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("voiceStage"))
        let oldDraft = try JSONDecoder().decode(ProductCreationDraft.self, from: oldData)
        XCTAssertEqual(oldDraft.pendingVoiceStage, .recorded)
        for stage in [ProductVoiceStage.recorded, .transcribed, .applied] {
            d.voiceStage = stage
            d.transcript = stage == .recorded ? "" : "Синтетическая диктовка"
            let restored = try JSONDecoder().decode(ProductCreationDraft.self, from: JSONEncoder().encode(d))
            XCTAssertEqual(restored, d)
            XCTAssertEqual(restored.pendingVoiceStage, stage == .applied ? nil : stage)
            XCTAssertEqual(try restored.product().protein, Decimal(string: "2.9"))
        }
    }
    func testSaveFailureKeepsDraftAndRepeatedSaveIsIdempotent() async throws {
        let container = try DiaryStore.makeContainer(memory: true), d = draft()
        let repository = ProductRepository(container: container)
        try await repository.persist(d)
        await repository.injectSaveFailure()
        do { _ = try await repository.commit(d); XCTFail("Expected disk failure") } catch {}
        let restored = try await repository.loadDraft(), none = try await repository.search("")
        XCTAssertEqual(restored, d); XCTAssertTrue(none.isEmpty)
        _ = try await repository.commit(d); _ = try await repository.commit(d)
        let all = try await repository.search("")
        XCTAssertEqual(all.count, 1)
    }
    func testBarcodeUniquenessAndOverridesExternalCatalog() async throws {
        let container = try DiaryStore.makeContainer(memory: true)
        let repository = ProductRepository(container: container)
        var d = draft(); d.barcode = "4600605026533"; d.protein = "3.01"
        _ = try await repository.commit(d)
        var other = draft(); other.barcode = d.barcode
        do { _ = try await repository.commit(other); XCTFail("Duplicate barcode accepted") } catch {}
        let store = DiaryStore(container: container, catalog: Catalog(url: Bundle.main.url(forResource: "catalog", withExtension: "sqlite")))
        let result = try await store.search(d.barcode)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.protein, Decimal(string: "3.01"))
    }
    func testScannedIdentityKeepsEnteredFieldsAndNutrition() throws {
        var d = draft(); d.name = ""; d.barcode = "036000291452"
        let original = d
        var suggestion = try draft().product()
        suggestion.barcode = d.barcode; suggestion.name = "Синтетическое название каталога"
        suggestion.brand = "Другой бренд"; suggestion.basis = .unknown; suggestion.protein = 99
        suggestion.source = "https://example.invalid/synthetic-product"; suggestion.sourceModified = "synthetic-revision"
        XCTAssertTrue(d.fillIdentity(from: suggestion))
        XCTAssertEqual(d.name, suggestion.name); XCTAssertEqual(d.brand, original.brand)
        XCTAssertEqual(d.basis, original.basis); XCTAssertEqual(d.protein, original.protein)
        XCTAssertEqual(d.calories, original.calories); XCTAssertEqual(d.fat, original.fat); XCTAssertEqual(d.carbs, original.carbs)
        XCTAssertEqual(try d.product().source, "user-label")
        XCTAssertEqual(try d.product().identitySource?.url, suggestion.source)
        XCTAssertEqual(try d.product().identitySource?.license, "ODbL 1.0")
        let restored = try JSONDecoder().decode(ProductCreationDraft.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(restored, d)
        let filled = d
        XCTAssertFalse(d.fillIdentity(from: suggestion)); XCTAssertEqual(d, filled)
        d.name = ""; suggestion.barcode = "4600605026533"
        XCTAssertFalse(d.fillIdentity(from: suggestion)); XCTAssertTrue(d.name.isEmpty)
    }
    func testScanPersistsCodeWhenCatalogUnavailableAndKeepsLeadingZero() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("test.store")
        let library = ProductLibrary(container: try DiaryStore.makeContainer(url: location))
        await library.begin()
        library.draft = draft()
        let status = await library.scan("036000291452", catalog: Catalog(url: nil))
        XCTAssertNotNil(status); XCTAssertNil(library.error)
        XCTAssertEqual(library.draft?.name, draft().name)
        let restored = try await ProductRepository(container: DiaryStore.makeContainer(url: location)).loadDraft()
        XCTAssertEqual(restored?.barcode, "036000291452")
        XCTAssertEqual(restored, library.draft)
        let products = try await library.repository.search("")
        XCTAssertTrue(products.isEmpty, "Скан не подтверждает создание продукта")
    }
    func testScanLooksUpNameWithoutImportingNutritionAndRejectsDuplicate() async throws {
        let library = ProductLibrary(container: try DiaryStore.makeContainer(memory: true))
        let catalog = Catalog(url: try XCTUnwrap(Bundle.main.url(forResource: "catalog", withExtension: "sqlite")))
        await library.begin()
        let unknown = await library.scan("0000000000017", catalog: catalog)
        XCTAssertNotNil(unknown); XCTAssertTrue(try XCTUnwrap(library.draft).name.isEmpty)
        XCTAssertEqual(library.draft?.barcode, "0000000000017"); XCTAssertNil(library.draft?.identitySource)
        let status = await library.scan("4600605026533", catalog: catalog)
        XCTAssertNotNil(status); XCTAssertFalse(try XCTUnwrap(library.draft).name.isEmpty)
        XCTAssertTrue(try XCTUnwrap(library.draft).calories.isEmpty)
        XCTAssertTrue(try XCTUnwrap(library.draft).protein.isEmpty)
        XCTAssertNotNil(library.draft?.identitySource)
        library.draft?.protein = "2,9"; library.draft?.fat = "1.5"; library.draft?.carbs = "4,9"
        await library.commit()
        let saved = try XCTUnwrap(library.products.first)
        await library.begin()
        let original = library.draft
        let duplicate = await library.scan("4600605026533", catalog: catalog)
        XCTAssertNil(duplicate); XCTAssertNotNil(library.error); XCTAssertEqual(library.draft, original)
        library.error = nil; library.draft = ProductCreationDraft(product: saved)
        let edit = await library.scan("4600605026533", catalog: catalog)
        XCTAssertNotNil(edit); XCTAssertNil(library.error); XCTAssertEqual(library.draft?.editingProductID, saved.id)
    }
    func testScanSaveFailureKeepsCodeForRetry() async throws {
        let library = ProductLibrary(container: try DiaryStore.makeContainer(memory: true))
        await library.begin(); try await library.flush()
        await library.repository.injectSaveFailure()
        let failed = await library.scan("036000291452", catalog: Catalog(url: nil))
        XCTAssertNil(failed); XCTAssertNotNil(library.error)
        XCTAssertEqual(library.draft?.barcode, "036000291452")
        library.error = nil
        let retry = await library.scan("036000291452", catalog: Catalog(url: nil))
        XCTAssertNotNil(retry); XCTAssertNil(library.error)
        let restored = try await library.repository.loadDraft()
        XCTAssertEqual(restored?.barcode, "036000291452")
        let invalid = await library.scan("4600605026534", catalog: Catalog(url: nil))
        XCTAssertNil(invalid); XCTAssertEqual(library.draft?.barcode, "036000291452")
    }
    func testV1MigrationKeepsExistingDiaryAndFoodDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let location = directory.appendingPathComponent("test.store")
        let product = try draft().product(), day = Day(rawValue: "2026-09-07")
        let food = FoodDraft(day: day, meal: .breakfast, product: product, quantity: "100", basis: .ml)
        func createV1() throws {
            let schema = Schema(versionedSchema: PersonalSchema.self)
            let config = ModelConfiguration(schema: schema, url: location, cloudKitDatabase: .none)
            let old = try ModelContainer(for: schema, configurations: config), context = ModelContext(old)
            context.insert(PersonalSchema.Record(id: UUID(), day: day, meal: .breakfast,
                productData: try JSONEncoder().encode(product), amount: "100", unit: .ml))
            context.insert(PersonalSchema.DraftRecord(try JSONEncoder().encode(food)))
            try context.save()
        }
        try createV1()
        let container = try DiaryStore.makeContainer(url: location)
        let store = DiaryStore(container: container, catalog: Catalog(url: nil)); store.select(day)
        XCTAssertEqual(store.total.protein, Decimal(string: "2.9")); XCTAssertEqual(store.draft, food)
        let repo = ProductRepository(container: container)
        try await repo.persist(draft())
        let newDraft = try await repo.loadDraft()
        XCTAssertNotNil(newDraft)
    }
    func testEditingDiaryQuantityDoesNotRevertCatalogEdit() async throws {
        let container = try DiaryStore.makeContainer(memory: true), repo = ProductRepository(container: container)
        let d = draft(), p = try await repo.commit(d)
        let store = DiaryStore(container: container, catalog: Catalog(url: nil))
        try store.persistDraft(FoodDraft(day: store.today, meal: .breakfast, product: p, quantity: "100", basis: .ml))
        try store.commitDraft()
        let old = try XCTUnwrap(store.items.first)
        var edit = ProductCreationDraft(product: p); edit.protein = "7.8"
        _ = try await repo.commit(edit)
        store.edit(old); store.editDraft { $0.quantity = "200" }; try store.commitDraft()
        let current = try await store.search("Тестовое")
        XCTAssertEqual(current.first?.protein, Decimal(string: "7.8"))
        XCTAssertEqual(store.items.first?.product?.protein, Decimal(string: "2.9"))
    }

    func testVoiceManifestIsPinnedAndIncludesBothRuntimeArtifacts() throws {
        let manifest = try VoiceManifest.bundled()
        XCTAssertEqual(manifest.totalBytes, 2_762_075_342)
        XCTAssertTrue(manifest.models.flatMap(\.files).allSatisfy { $0.bytes > 0 && $0.sha256.count == 64 })
        XCTAssertTrue(manifest.models.first?.files.contains { $0.path == "JointDecisionv3.mlmodelc/model.mil" } == true)
    }
}
