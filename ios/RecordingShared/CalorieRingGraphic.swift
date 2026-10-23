import SwiftUI

enum CalorieRingMetrics {
    static let strokeWidth: CGFloat = 9
}

/// Shared verbatim by the diary card and the home-screen widget.
struct CalorieRingLabels: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: String
    let caption: String
    var animates = true

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(typeSize.isAccessibilitySize ? .largeTitle.weight(.bold) : .system(size: 36, weight: .bold))
                .monospacedDigit().contentTransition(!animates || reduceMotion ? .identity : .numericText())
                .minimumScaleFactor(0.5).lineLimit(1).accessibilityIdentifier("calorieValue")
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }.padding(10)
    }
}

struct CalorieRingGraphic<Labels: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: Double
    let exceeded: Bool
    var diameter: CGFloat = 128
    var animates = true
    @ViewBuilder let labels: () -> Labels

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(.green.opacity(0.13), style: StrokeStyle(lineWidth: CalorieRingMetrics.strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * progress)
                .stroke(exceeded ? Color.orange : Color.green, style: StrokeStyle(lineWidth: CalorieRingMetrics.strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(!animates || reduceMotion ? nil : .smooth(duration: 0.4), value: progress)
            labels()
        }.frame(width: diameter, height: diameter)
    }
}
