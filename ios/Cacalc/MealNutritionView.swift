import SwiftUI

/// Day totals include the pending meal; the smaller amount is this meal's contribution.
struct MealNutritionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var trackWidth: CGFloat = 110
    let preview: MealNutritionPreview
    let recommendation: PortionSnapshot?
    let future: Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], spacing: 22) {
            values
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .onGeometryChange(for: CGFloat.self) { geometry in
            // Both screens have 20 pt outer margins. Diary adds 18 pt card
            // padding per side and two 16 pt gaps between three indicators.
            max(0, (geometry.size.width - 36 - 32) / 3)
        } action: { trackWidth = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.65), value: preview.added.known)
    }

    @ViewBuilder private var values: some View {
        metric("Калории", name: "Калории", unit: "ккал", value: preview.nutrient(\.calories, missing: \.missingCalories),
            recommendation: recommendation?.calories, color: .green, id: "mealPreviewAdded")
        metric("Белки", name: "Белки", unit: "г", value: preview.nutrient(\.protein, missing: \.missingProtein),
            recommendation: recommendation?.protein, color: .cyan, id: "mealPreview_protein")
        metric("Жиры", name: "Жиры", unit: "г", value: preview.nutrient(\.fat, missing: \.missingFat),
            recommendation: recommendation?.fat, color: .orange, id: "mealPreview_fat")
        metric("Углеводы", name: "Углеводы", unit: "г", value: preview.nutrient(\.carbs, missing: \.missingCarbs),
            recommendation: recommendation?.carbs, color: .indigo, id: "mealPreview_carbs")
    }

    private func metric(_ title: String, name: String, unit: String, value: MealNutrientPreview,
                        recommendation: Decimal?, color: Color, id: String) -> some View {
        MacroIndicator(title: title, eaten: value.total, target: value.target, color: color,
                       missing: value.totalMissing, valueText: compact(value.totalText),
                       additionText: contributionText(value),
                       beforeEaten: value.before, trackWidth: trackWidth, compactLayout: false,
                       animatesValue: !reduceMotion, mealRecommendation: recommendation)
            .foregroundStyle(.primary)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .accessibilityIdentifier(id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("После добавления: " + value.totalText + ". Прибавка: " + (value.addedText.isEmpty ? "0" : value.addedText)
            + (recommendation.map { ". Ориентир приёма: примерно " + Numbers.display($0, places: 0) + " " + unit } ?? ""))
        .accessibilityHint(value.target.map { "Цель: " + Numbers.display($0, places: 0) } ?? "Цель не задана")
    }

    private func contributionText(_ value: MealNutrientPreview) -> String? {
        if value.addedMissing == 0 && value.added == 0 { return nil }
        return compact(value.addedText)
    }

    private func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
}
