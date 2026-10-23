import Foundation

@main struct NutritionWidgetChecks {
    static func main() throws {
        precondition(NutritionWidgetSnapshot.allKinds.count == 6)
        precondition(Set(NutritionWidgetSnapshot.allKinds).count == 6)
        let normal = WidgetNutrient(known: 700, target: 2200, missing: 0)
        precondition(normal.remaining == 1500 && normal.calorieLabel == "Осталось")
        precondition(normal.calorieValue == "1500")
        let over = WidgetNutrient(known: 2400, target: 2200, missing: 0)
        precondition(over.remaining == 200 && over.exceeded && over.progress == 1)
        precondition(over.calorieLabel == "Сверх цели")
        precondition(over.compactCalorieValue == "+200")
        precondition(normal.compactCalorieValue == "1500")
        let unknown = WidgetNutrient(known: 700, target: 2200, missing: 1)
        precondition(unknown.remaining == nil && unknown.calorieValue == "≥ 700")
        precondition(unknown.calorieLabel == "Известно")
        precondition(unknown.compactCalorieValue == "≥ 700")
        let noGoal = WidgetNutrient(known: 700, target: nil, missing: 0)
        precondition(noGoal.remaining == nil && noGoal.calorieLabel == "Съедено")
        precondition(WidgetNutrient(known: 1, target: 0, missing: 0).progress == 0)
        let decimal = WidgetNutrient(known: Decimal(string: "10.25")!, target: 100, missing: 0)
        precondition(decimal.remaining == Decimal(string: "89.75")!)
        precondition(decimal.ringRemainingValue == "90")
        precondition(normal.ringRemainingValue == "1500")
        precondition(over.ringRemainingValue == "+200")
        precondition(unknown.ringRemainingValue == "—")
        precondition(noGoal.ringRemainingValue == "—")
        precondition(WidgetNutrient(known: 100, target: 100, missing: 0).ringRemainingValue == "0")
        precondition(decimal.compactMacroValue == "10")
        precondition(unknown.compactMacroValue == "≥700")
        precondition(noGoal.compactMacroValue == "700")
        precondition(WidgetNutrient(known: 0, target: 150, missing: 0).compactMacroValue == "0")
        let zone = TimeZone(identifier: "Europe/Moscow")!
        let first = NutritionWidgetDay(day: "2026-09-23", calories: normal, protein: decimal, fat: unknown, carbs: noGoal)
        let second = NutritionWidgetDay(day: "2026-09-24", calories: .init(known: 0, target: 2200, missing: 0),
                                       protein: decimal, fat: decimal, carbs: decimal)
        let snapshot = NutritionWidgetSnapshot(timeZone: zone.identifier, days: [first, second])
        let decoded = try JSONDecoder().decode(NutritionWidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        precondition(decoded == snapshot)
        let date = ISO8601DateFormatter()
        precondition(decoded.value(at: date.date(from: "2026-09-23T20:59:59Z")!, zone: zone) == first)
        precondition(decoded.value(at: date.date(from: "2026-09-23T21:00:00Z")!, zone: zone) == second)
        precondition(decoded.value(at: date.date(from: "2026-09-24T21:00:00Z")!, zone: zone) == nil)
        precondition(decoded.value(at: date.date(from: "2026-09-23T15:00:00Z")!, zone: TimeZone(secondsFromGMT: 0)!) == nil)
        var futureVersion = decoded
        futureVersion.version = 2
        precondition(futureVersion.value(at: date.date(from: "2026-09-23T15:00:00Z")!, zone: zone) == nil)
        print("PASS: widget decimals, partial nutrition, goals, overflow, serialization, midnight, stale day, time zone, schema")
    }
}
