import Foundation
import SQLite3

actor Catalog {
    private let url: URL?
    private var keyColumn = "barcode"
    nonisolated(unsafe) private var db: OpaquePointer?
    init(url: URL?) { self.url = url }
    deinit { if let db { sqlite3_close(db) } }
    static nonisolated func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "ru_RU"))
            .replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private func connect() throws -> OpaquePointer {
        if let db { return db }
        guard let url else { throw FoodError.database("Файл каталога не включён в сборку.") }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw FoodError.database("Не удалось открыть каталог продуктов.")
        }
        func pragma(_ sql: String) -> Int32 {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return sqlite3_column_int(statement, 0)
        }
        let version = pragma("PRAGMA user_version")
        guard pragma("PRAGMA application_id") == 1128350529, [1, 2].contains(version) else {
            sqlite3_close(handle); throw FoodError.database("Неподдерживаемая версия каталога.")
        }
        keyColumn = version == 2 ? "id" : "barcode"
        db = handle; return handle
    }
    func search(_ raw: String) throws -> [Product] {
        try Task.checkCancellation()
        guard !Self.normalize(raw).isEmpty else { return [] }
        return try entries(raw, limit: 30)
    }
    /// The basic catalog is small; List renders its rows lazily, without hiding results.
    func browse(_ raw: String = "") throws -> [Product] {
        try entries(raw, limit: nil)
    }
    private func entries(_ raw: String, limit: Int?) throws -> [Product] {
        try Task.checkCancellation()
        let query = Self.normalize(raw)
        let db = try connect()
        let exact = [8, 12, 13, 14].contains(query.count) && query.utf8.allSatisfy { (48...57).contains($0) }
        let sql = "SELECT \(keyColumn),name,brands,basis_unit,energy_kcal_100,protein_g_100,fat_g_100,carbohydrate_g_100,source_url,source_modified_at,issues_json,raw_nutrition_json,barcode FROM products WHERE " +
            (exact ? "barcode = ?" : "instr(search_name, ?) > 0 ORDER BY (energy_kcal_100 IS NULL OR protein_g_100 IS NULL OR fat_g_100 IS NULL OR carbohydrate_g_100 IS NULL),name " + (limit.map { " LIMIT \($0)" } ?? ""))
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw FoodError.database("Не удалось выполнить поиск.") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, query, -1, transient)
        func text(_ n: Int32) -> String? { sqlite3_column_text(statement, n).map { String(cString: $0) } }
        var result: [Product] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            let code = text(0)!
            var product = Product(id: code, barcode: text(12), name: text(1)!, brand: text(2) ?? "",
                basis: Basis(rawValue: text(3) ?? "") ?? .unknown,
                calories: Numbers.source(text(4)), protein: Numbers.source(text(5)), fat: Numbers.source(text(6)), carbs: Numbers.source(text(7)),
                source: text(8) ?? "openfoodfacts", sourceModified: text(9), issues: text(10) ?? "")
            if code.hasPrefix("basic:"), let rawData = text(11)?.data(using: .utf8),
               let metadata = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
               let license = metadata["license"] as? String {
                product.identitySource = ProductIdentitySource(url: product.source, modifiedAt: product.sourceModified, license: license)
            }
            result.append(product)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw FoodError.database("Ошибка чтения каталога.") }
        return result
    }
}
