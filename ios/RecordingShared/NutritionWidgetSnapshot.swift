import Foundation
import Security

struct WidgetNutrient: Codable, Equatable, Sendable {
    var known: Decimal
    var target: Decimal?
    var missing: Int
    var exceeded: Bool { missing == 0 && target.map { known > $0 } == true }
    var remaining: Decimal? { missing == 0 ? target.map { abs($0 - known) } : nil }
    var progress: Double {
        guard let target, target > 0 else { return 0 }
        return min(1, max(0, NSDecimalNumber(decimal: known / target).doubleValue))
    }
    var calorieValue: String { (missing > 0 ? "≥ " : "") + Self.text(remaining ?? known) }
    var compactCalorieValue: String { (exceeded ? "+" : "") + calorieValue }
    var ringRemainingValue: String {
        guard let remaining else { return "—" }
        return (exceeded ? "+" : "") + Self.text(remaining)
    }
    var calorieLabel: String {
        missing > 0 ? "Известно" : target == nil ? "Съедено" : exceeded ? "Сверх цели" : "Осталось"
    }
    var macroValue: String {
        (missing > 0 ? "≥ " : "") + Self.text(known) + (target.map { " / " + Self.text($0) } ?? "") + " г"
    }
    var compactMacroValue: String { (missing > 0 ? "≥" : "") + Self.text(known) }
    static func text(_ value: Decimal) -> String {
        let format = NumberFormatter()
        format.locale = Locale(identifier: "ru_RU")
        format.numberStyle = .decimal
        format.maximumFractionDigits = 0
        format.usesGroupingSeparator = false
        return format.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
}

struct NutritionWidgetDay: Codable, Equatable, Sendable {
    var day: String
    var calories: WidgetNutrient
    var protein: WidgetNutrient
    var fat: WidgetNutrient
    var carbs: WidgetNutrient
}

struct NutritionWidgetSnapshot: Codable, Equatable, Sendable {
    static let kind = "DailyNutrition"
    static let caloriesKind = "LockScreenCalories"
    static let macrosKind = "LockScreenMacros"
    static let proteinKind = "LockScreenProtein"
    static let fatKind = "LockScreenFat"
    static let carbsKind = "LockScreenCarbs"
    static let allKinds = [kind, caloriesKind, macrosKind, proteinKind, fatKind, carbsKind]
    var version = 1
    var timeZone: String
    var days: [NutritionWidgetDay]
    func value(at date: Date, zone: TimeZone = .autoupdatingCurrent) -> NutritionWidgetDay? {
        guard version == 1, zone.identifier == timeZone else { return nil }
        return days.first { $0.day == Self.dayKey(date, zone: zone) }
    }
    static func dayKey(_ date: Date, zone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year!, values.month!, values.day!)
    }
}

/// Only aggregate nutrition is shared. Private API credentials remain in the app's own group.
enum NutritionWidgetCache {
    private static func query() throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "NutritionWidgetKeychainGroup") as? String,
              !group.contains("$("), !group.isEmpty else { throw CacheError.configuration }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "local.cacalc.nutrition-widget",
                kSecAttrAccount as String: "snapshot-v1",
                kSecAttrAccessGroup as String: group]
    }
    static func read() throws -> NutritionWidgetSnapshot? {
        var attributes = try query()
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CacheError.security(status) }
        return try JSONDecoder().decode(NutritionWidgetSnapshot.self, from: data)
    }
    @discardableResult static func write(_ snapshot: NutritionWidgetSnapshot) throws -> Bool {
        if (try? read()) == snapshot { return false }
        let base = try query()
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(snapshot),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CacheError.security(status) }
        guard try read() == snapshot else { throw CacheError.verification }
        return true
    }
    enum CacheError: Error { case configuration, verification, security(OSStatus) }
}
