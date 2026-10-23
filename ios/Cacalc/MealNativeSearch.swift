import SwiftUI

/// Results live inside the same List/navigation container as the system search field.
struct MealNativeSearch: View {
    let query: String
    let suggested: [Product]
    let products: [Product]
    let error: String?
    let select: (Product) -> Void
    let quickEntry: () -> Void
    let addUnknown: (String) -> Void
    private var emptyQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var visibleProducts: [Product] {
        guard emptyQuery else { return products }
        var ids = Set<String>()
        return Array((suggested + products).filter { ids.insert($0.id).inserted }.prefix(12))
    }
    var body: some View {
        Section {
            Button("Быстрый ввод", systemImage: "square.and.pencil", action: usageAction("MealNativeSearch.button.21", quickEntry))
                .accessibilityIdentifier("mealQuickEntry")
            ForEach(visibleProducts) { product in
                Button { UsageTelemetry.shared.action("MealNativeSearch.button.24"); select(product) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(product.name).foregroundStyle(Color(uiColor: .label))
                        if !product.brand.isEmpty { Text(product.brand).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }.accessibilityIdentifier("mealSearch_" + product.id)
            }
            if emptyQuery && visibleProducts.isEmpty {
                Text("Найдите продукт по названию. Здесь будут ваши сохранённые продукты.").foregroundStyle(.secondary)
            }
            if !emptyQuery { Button("Добавить «\(query)»") { UsageTelemetry.shared.action("MealNativeSearch.button.34"); addUnknown(query) }.accessibilityIdentifier("mealAddUnknown") }
            if let error { Text(error).foregroundStyle(.secondary) }
        } header: {
            Text(emptyQuery ? "Предложения" : "Продукты")
                .font(.headline).foregroundStyle(Color(uiColor: .label)).textCase(nil)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 10, trailing: 0))
        }

    }
}

/// Keep navigation geometry stable while fading complete controls, including glass.
struct MealSearchFadingControl: ViewModifier {
    let hidden: Bool
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.25), value: hidden)
    }
}

/// The hidden return position can be closer without changing the outgoing movement.
nonisolated struct MealContentReveal: AnimatableModifier {
    var progress: Double
    let travel: CGFloat
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .offset(y: -travel * (1 - progress))
    }
}
