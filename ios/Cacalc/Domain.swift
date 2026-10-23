import Foundation

enum FoodError: LocalizedError {
    case invalidNumber, missingNutrition, unknownBasis, wrongUnit, invalidBarcode, database(String)
    var errorDescription: String? {
        switch self {
        case .invalidNumber: "Введите корректное число. Количество и цели должны быть больше нуля."
        case .missingNutrition: "Для записи нужны калории и все три значения БЖУ. Дополните карточку по упаковке."
        case .unknownBasis: "Подтвердите, на 100 г или на 100 мл указаны значения на упаковке."
        case .wrongUnit: "Единица количества должна совпадать с основой КБЖУ."
        case .invalidBarcode: "Штрихкод должен содержать 8, 12, 13 или 14 цифр с верной контрольной цифрой."
        case .database(let message): message
        }
    }
}

enum Numbers {
    static func parse(_ text: String, positive: Bool = false) throws -> Decimal {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard input.count <= 32, input.range(of: #"^\d+(\.\d{0,18})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: input, locale: Locale(identifier: "en_US_POSIX")),
              value <= 1_000_000, positive ? value > 0 : value >= 0 else { throw FoodError.invalidNumber }
        return value
    }
    static func source(_ text: String?) -> Decimal? {
        guard let text else { return nil }
        return try? parse(text)
    }
    static func string(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    static func display(_ value: Decimal, places: Int = 1, grouping: Bool = true) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = places
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
}

struct Nutrition: Codable, Equatable, Sendable {
    var calories: Decimal
    var protein: Decimal
    var fat: Decimal
    var carbs: Decimal
    static let zero = Nutrition(calories: 0, protein: 0, fat: 0, carbs: 0)
    func scaled(_ amount: Decimal) -> Self {
        Self(calories: calories * amount / 100, protein: protein * amount / 100,
             fat: fat * amount / 100, carbs: carbs * amount / 100)
    }
    static func + (lhs: Self, rhs: Self) -> Self {
        Self(calories: lhs.calories + rhs.calories, protein: lhs.protein + rhs.protein,
             fat: lhs.fat + rhs.fat, carbs: lhs.carbs + rhs.carbs)
    }
}

enum Basis: String, Codable, CaseIterable, Sendable {
    case unknown, g, ml
    var title: String { switch self { case .unknown: "Не выбрано"; case .g: "г"; case .ml: "мл" } }
}

enum Meal: String, Codable, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, dinner, snack
    var id: String { rawValue }
    var title: String { switch self { case .breakfast: "Завтрак"; case .lunch: "Обед"; case .dinner: "Ужин"; case .snack: "Перекус" } }
    var icon: String { switch self { case .breakfast: "sun.horizon"; case .lunch: "sun.max"; case .dinner: "moon"; case .snack: "carrot" } }
}

struct Day: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ date: Date, zone: TimeZone = .autoupdatingCurrent) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        rawValue = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    var date: Date {
        let pieces = rawValue.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .autoupdatingCurrent
        return calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2], hour: 12))!
    }
    func offset(_ days: Int) -> Self {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .autoupdatingCurrent
        return Day(calendar.date(byAdding: .day, value: days, to: date)!)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    static func swipe(_ horizontal: Double, vertical: Double) -> Int {
        guard abs(horizontal) > 65, abs(horizontal) > abs(vertical) * 1.5 else { return 0 }
        return horizontal < 0 ? 1 : -1
    }
    func title(relativeTo today: Day) -> String {
        if self == today { return "Сегодня" }
        if self == today.offset(-1) { return "Вчера" }
        if self == today.offset(1) { return "Завтра" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEEE dd.MM"
        let value = formatter.string(from: date)
        return value.prefix(1).uppercased() + value.dropFirst()
    }
    static func streak(_ days: Set<Day>, today: Day) -> Int {
        var cursor = days.contains(today) ? today : today.offset(-1)
        var result = 0
        while days.contains(cursor) { result += 1; cursor = cursor.offset(-1) }
        return result
    }
}

struct ProductIdentitySource: Codable, Equatable, Sendable {
    var url: String
    var modifiedAt: String?
    var license: String
}

struct Product: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var barcode: String?
    var name: String
    var brand: String
    var basis: Basis
    var calories: Decimal?
    var protein: Decimal?
    var fat: Decimal?
    var carbs: Decimal?
    var source: String
    var sourceModified: String?
    var manufacturer: String? = nil
    var spokenDescription: String? = nil
    var identitySource: ProductIdentitySource? = nil
    var preparedBatchID: UUID? = nil
    var preparedNote: String? = nil
    var displayDetail: String { preparedNote ?? brand }
    var issues: String = ""
    var nutrition: Nutrition? {
        guard let calories, let protein, let fat, let carbs else { return nil }
        return Nutrition(calories: calories, protein: protein, fat: fat, carbs: carbs)
    }
    func portion(_ amount: Decimal, unit: Basis) throws -> Nutrition {
        guard let nutrition else { throw FoodError.missingNutrition }
        guard basis != .unknown else { throw FoodError.unknownBasis }
        guard unit == basis else { throw FoodError.wrongUnit }
        guard amount > 0, amount <= 1_000_000 else { throw FoodError.invalidNumber }
        return nutrition.scaled(amount)
    }
}

struct FoodDraft: Codable, Equatable, Sendable {
    var draftID: UUID? = UUID()
    var day: Day
    var meal: Meal
    var product: Product?
    var quantity = ""
    var basis: Basis = .unknown
    var editingID: UUID?
    var query = ""
    var custom = false
    var savesPersonalProduct: Bool? = nil
    var customName = ""
    var customBarcode = ""
    var customCalories = ""
    var customProtein = ""
    var customFat = ""
    var customCarbs = ""
}

struct DiaryItem: Identifiable, Equatable, Sendable {
    var id: UUID
    var day: Day
    var meal: Meal
    var row: MealRow
    var product: Product? { row.product }
    var amount: Decimal? { row.amount }
    var unit: FoodUnit? { row.unit }
    var total: Nutrition { row.portion.known }
    init(id: UUID, day: Day, meal: Meal, row: MealRow) {
        self.id = id; self.day = day; self.meal = meal; self.row = row
    }
    init(id: UUID, day: Day, meal: Meal, product: Product, amount: Decimal, unit: Basis) {
        self.id = id; self.day = day; self.meal = meal
        row = MealRow(id: id, food: product.name, quantity: Numbers.string(amount),
                      unit: FoodUnit(rawValue: unit.rawValue), product: product)
        row.snapshot = row.portion
    }
}

struct Budget: Sendable {
    var eaten: Decimal
    var target: Decimal?
    var exceeded: Bool { target.map { eaten > $0 } ?? false }
    var remainder: Decimal? { target.map { abs($0 - eaten) } }
    var progress: Double {
        guard let target, target > 0 else { return 0 }
        return min(1, max(0, NSDecimalNumber(decimal: eaten / target).doubleValue))
    }
}

enum Barcode {
    static func valid(_ code: String) -> Bool {
        guard [8, 12, 13, 14].contains(code.count), code.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        let digits = code.utf8.map { Int($0 - 48) }
        let sum = digits.dropLast().reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 3 : 1) }
        return (10 - sum % 10) % 10 == digits.last!
    }
}

struct StoredDataIssue: Identifiable, Equatable, Sendable {
    var id: String
    var message: String
}
struct DiaryPageData: Sendable {
    var items: [DiaryItem]
    var goals: Nutrition?
    var issues: [StoredDataIssue] = []
    var summary: NutritionSummary { NutritionSummary(items.filter { $0.row.timing?.isPlanned != true }.map { $0.row.portion }) }
    var total: Nutrition { summary.known }
}
