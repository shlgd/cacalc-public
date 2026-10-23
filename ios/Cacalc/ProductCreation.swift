import Foundation
import CoreFoundation

enum ProductVoiceStage: String, Codable, Sendable { case recorded, transcribed, applied }

struct ProductCreationDraft: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var productID: String? = UUID().uuidString
    var revision: UUID?
    var operationID: UUID?
    var editingProductID: String?
    var name = ""
    var brand = ""
    var manufacturer = ""
    var barcode = ""
    var basis = Basis.g
    var calories = ""
    var protein = ""
    var fat = ""
    var carbs = ""
    var transcript = ""
    var audioFile: String?
    var voiceStage: ProductVoiceStage?
    var identitySource: ProductIdentitySource?
    var notices: [String] = []

    var pendingVoiceStage: ProductVoiceStage? {
        if let voiceStage { return voiceStage == .applied ? nil : voiceStage }
        // Recover unfinished audio from drafts written before the compact editor.
        return audioFile != nil && transcript.isEmpty ? .recorded : nil
    }

    init() {}
    init(product: Product) {
        editingProductID = product.id; name = product.name; brand = product.brand == "Моя карточка" ? "" : product.brand
        manufacturer = product.manufacturer ?? ""; barcode = product.barcode ?? ""; basis = product.basis
        calories = product.calories.map(Numbers.string) ?? ""; protein = product.protein.map(Numbers.string) ?? ""
        fat = product.fat.map(Numbers.string) ?? ""; carbs = product.carbs.map(Numbers.string) ?? ""
        transcript = product.spokenDescription ?? ""
        identitySource = product.identitySource
    }

    /// Scanning suggests identity only. Label nutrition and its basis remain the user's values.
    mutating func fillIdentity(from product: Product) -> Bool {
        guard product.barcode == barcode else { return false }
        var filled = false
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !product.name.isEmpty {
            name = product.name; filled = true
        }
        if brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !product.brand.isEmpty {
            brand = product.brand; filled = true
        }
        if filled {
            identitySource = ProductIdentitySource(url: product.source, modifiedAt: product.sourceModified, license: "ODbL 1.0")
        }
        return filled
    }
    func product() throws -> Product {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FoodError.database("Укажите название продукта.") }
        let code = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.isEmpty || Barcode.valid(code) else { throw FoodError.invalidBarcode }
        guard basis != .unknown else { throw FoodError.unknownBasis }
        var value = Product(id: editingProductID ?? productID ?? id.uuidString, barcode: code.isEmpty ? nil : code,
                            name: title, brand: brand.trimmingCharacters(in: .whitespacesAndNewlines), basis: basis,
                            calories: calories.isEmpty ? nil : try Numbers.parse(calories),
                            protein: try Numbers.parse(protein), fat: try Numbers.parse(fat), carbs: try Numbers.parse(carbs),
                            source: "user-label")
        value.manufacturer = manufacturer.isEmpty ? nil : manufacturer
        value.spokenDescription = transcript.isEmpty ? nil : transcript
        value.identitySource = identitySource
        return value
    }
}

/// Qwen owns language interpretation. This boundary validates only the JSON contract;
/// it does not infer nutrients from word order or try to understand the sentence again.
struct ProductExtraction: Codable, Sendable {
    let name: String
    let brand: String?
    let manufacturer: String?
    let basis: String?
    let calories: Decimal?
    let protein: Decimal?
    let fat: Decimal?
    let carbs: Decimal?

    private static let numericKeys = ["calories", "protein", "fat", "carbs"]
    private static let keys = Set(["name", "brand", "manufacturer", "basis"] + numericKeys)

    static func decode(_ output: String) throws -> Self {
        do {
            var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            // Accept one fenced JSON block, but never hunt for a JSON fragment in prose.
            if text.hasPrefix("```"), text.hasSuffix("```") {
                text = text.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
            }
            guard text.utf8.count <= 16_384 else { throw FoodError.invalidNumber }
            let data = Data(text.utf8)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: keys), object["name"] is String else { throw FoodError.invalidNumber }
            for (key, limit) in [("name", 200), ("brand", 200), ("manufacturer", 300)] {
                guard let value = object[key], !(value is NSNull) else { continue }
                guard let string = value as? String, string.count <= limit else { throw FoodError.invalidNumber }
            }
            for key in numericKeys {
                guard let value = object[key], !(value is NSNull) else { continue }
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw FoodError.invalidNumber }
            }
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.basis == nil || value.basis == "g" || value.basis == "ml" else { throw FoodError.unknownBasis }
            for number in [value.calories, value.protein, value.fat, value.carbs].compactMap({ $0 }) {
                // Same Decimal limits as manual entry; no floating-point rounding.
                _ = try Numbers.parse(Numbers.string(number))
            }
            return value
        } catch {
            throw FoodError.database("Модель вернула ответ неподходящего формата. Описание и поля сохранены — попробуйте разобрать ещё раз.")
        }
    }

    func applying(to original: ProductCreationDraft) -> ProductCreationDraft {
        var draft = original
        draft.notices = []
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { draft.name = title }
        if let brand { draft.brand = brand.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let manufacturer { draft.manufacturer = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let basis, let known = Basis(rawValue: basis) { draft.basis = known }
        if let calories { draft.calories = Numbers.string(calories) }
        if let protein { draft.protein = Numbers.string(protein) }
        if let fat { draft.fat = Numbers.string(fat) }
        if let carbs { draft.carbs = Numbers.string(carbs) }
        return draft
    }
}
