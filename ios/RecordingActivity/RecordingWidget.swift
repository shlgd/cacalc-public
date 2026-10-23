import ActivityKit
import WidgetKit
import SwiftUI

@main struct RecordingWidgetBundle: WidgetBundle {
    var body: some Widget {
        NutritionWidget()
        CaloriesAccessoryWidget()
        ProteinAccessoryWidget()
        FatAccessoryWidget()
        CarbsAccessoryWidget()
        MacrosAccessoryWidget()
        RecordingWidget()
    }
}

struct NutritionEntry: TimelineEntry {
    let date: Date
    let day: NutritionWidgetDay?
}

struct NutritionProvider: TimelineProvider {
    func placeholder(in context: Context) -> NutritionEntry { NutritionEntry(date: .now, day: nil) }
    func getSnapshot(in context: Context, completion: @escaping (NutritionEntry) -> Void) {
        let now = Date()
        completion(NutritionEntry(date: now, day: (try? NutritionWidgetCache.read())?.value(at: now)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NutritionEntry>) -> Void) {
        let now = Date()
        let snapshot = try? NutritionWidgetCache.read()
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: now)
        // Explicit midnight entries prevent yesterday's total lingering into a new day.
        let dates = [now] + (1...8).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let entries = dates.map { NutritionEntry(date: $0, day: snapshot?.value(at: $0)) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct NutritionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NutritionWidgetSnapshot.kind, provider: NutritionProvider()) { entry in
            NutritionWidgetView(entry: entry)
                .containerBackground(Color(uiColor: .secondarySystemGroupedBackground), for: .widget)
                .widgetURL(URL(string: "cacalc://diary"))
                .environment(\.locale, Locale(identifier: "ru_RU"))
        }
        .configurationDisplayName("Калории и БЖУ")
        .description("Остаток калорий и белки, жиры, углеводы за сегодня.")
        .supportedFamilies([.systemMedium])
    }
}

struct NutritionWidgetView: View {
    @Environment(\.widgetContentMargins) private var contentMargins
    let entry: NutritionEntry
    private let macroBarHeight: CGFloat = 6
    var body: some View {
        if let day = entry.day {
            GeometryReader { geometry in
                // Reserve the stroke on both sides; center both columns on one axis.
                let diameter = max(0, min(128, geometry.size.height - 10, geometry.size.width * 0.42))
                let outerDiameter = diameter + CalorieRingMetrics.strokeWidth
                let gap = max(0, contentMargins.top + (geometry.size.height - outerDiameter) / 2)
                let fullWidth = geometry.size.width + contentMargins.leading + contentMargins.trailing
                NutritionCompositionLayout(ringWidth: outerDiameter, columnGap: gap,
                                           margins: contentMargins, barHeight: macroBarHeight) {
                    calorieRing(day.calories, diameter: diameter).frame(width: outerDiameter, height: outerDiameter)
                    macro("Белки", day.protein, .cyan)
                    macro("Жиры", day.fat, .orange)
                    macro("Углеводы", day.carbs, .indigo)
                }
                .frame(width: max(0, fullWidth - 2 * gap), height: geometry.size.height)
                .offset(x: gap - contentMargins.leading)
            }
            .privacySensitive()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "chart.pie").font(.title2).foregroundStyle(.green)
                Text("Калории и БЖУ").font(.headline)
                Text("Откройте дневник для обновления").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func calorieRing(_ value: WidgetNutrient, diameter: CGFloat) -> some View {
        CalorieRingGraphic(progress: value.progress, exceeded: value.exceeded, diameter: diameter, animates: false) {
            CalorieRingLabels(value: value.calorieValue, caption: value.calorieLabel, animates: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value.calorieLabel): \(value.calorieValue) килокалорий")
    }
    private func macro(_ title: String, _ value: WidgetNutrient, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value.macroValue).monospacedDigit()
            }.font(.caption).lineLimit(1).minimumScaleFactor(0.75)
            GeometryReader { geometry in
                Capsule().fill(color.opacity(0.16))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: geometry.size.width * value.progress)
                    }
            }.frame(height: macroBarHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value.macroValue)\(value.missing > 0 ? ". Часть значений неизвестна" : "")")
    }
}

private enum NutritionAccessoryContent {
    case calories, protein, fat, carbs, macros
    var kind: String {
        switch self {
        case .calories: NutritionWidgetSnapshot.caloriesKind
        case .protein: NutritionWidgetSnapshot.proteinKind
        case .fat: NutritionWidgetSnapshot.fatKind
        case .carbs: NutritionWidgetSnapshot.carbsKind
        case .macros: NutritionWidgetSnapshot.macrosKind
        }
    }
    var title: String {
        switch self {
        case .calories: "Остаток калорий"
        case .protein: "Остаток белков"
        case .fat: "Остаток жиров"
        case .carbs: "Остаток углеводов"
        case .macros: "Белки, жиры, углеводы"
        }
    }
    var letter: String {
        switch self {
        case .calories: "К"
        case .protein: "Б"
        case .fat: "Ж"
        case .carbs: "У"
        case .macros: ""
        }
    }
    func nutrient(in day: NutritionWidgetDay) -> WidgetNutrient {
        switch self {
        case .calories: day.calories
        case .protein: day.protein
        case .fat: day.fat
        case .carbs: day.carbs
        case .macros: day.calories // Rectangular content doesn't use the ring.
        }
    }
}

private struct CaloriesAccessoryWidget: Widget {
    var body: some WidgetConfiguration { nutritionAccessoryConfiguration(.calories) }
}

private struct MacrosAccessoryWidget: Widget {
    var body: some WidgetConfiguration { nutritionAccessoryConfiguration(.macros) }
}

private struct ProteinAccessoryWidget: Widget {
    var body: some WidgetConfiguration { nutritionAccessoryConfiguration(.protein) }
}
private struct FatAccessoryWidget: Widget {
    var body: some WidgetConfiguration { nutritionAccessoryConfiguration(.fat) }
}
private struct CarbsAccessoryWidget: Widget {
    var body: some WidgetConfiguration { nutritionAccessoryConfiguration(.carbs) }
}

@MainActor private func nutritionAccessoryConfiguration(_ content: NutritionAccessoryContent) -> some WidgetConfiguration {
        StaticConfiguration(kind: content.kind, provider: NutritionProvider()) { entry in
            LockScreenNutritionView(entry: entry, content: content)
                .containerBackground(.clear, for: .widget)
                .widgetURL(URL(string: "cacalc://diary"))
                .environment(\.locale, Locale(identifier: "ru_RU"))
        }
        .configurationDisplayName(content.title)
        .description(content == .macros ? "Съеденные граммы БЖУ и заполнение дневных целей." : "Остаток до дневной цели. Плюс означает превышение.")
        .supportedFamilies(content == .macros ? [.accessoryRectangular] : [.accessoryCircular])
        .contentMarginsDisabled()
}

private struct LockScreenNutritionView: View {
    let entry: NutritionEntry
    let content: NutritionAccessoryContent

    var body: some View {
        if let day = entry.day {
            GeometryReader { geometry in
                let diameter = max(0, min(geometry.size.height, geometry.size.width) - 8)
                Group {
                    if content != .macros {
                        ring(content.nutrient(in: day), diameter: diameter)
                    } else {
                        VStack(spacing: 5) {
                            macro("Белки", day.protein)
                            macro("Жиры", day.fat)
                            macro("Углеводы", day.carbs)
                        }.padding(.horizontal, 4)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
            .privacySensitive()
        } else {
            VStack(spacing: 2) {
                Image(systemName: "chart.pie")
                Text("Откройте\nдневник").font(.caption2).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func ring(_ value: WidgetNutrient, diameter: CGFloat) -> some View {
        Circle().trim(from: 0, to: 0.75)
                .stroke(.primary.opacity(0.22), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(135))
            .frame(width: diameter, height: diameter)
            .overlay {
            Circle().trim(from: 0, to: 0.75 * value.progress)
                .stroke(.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(135))
            }
            .overlay {
            Text(value.ringRemainingValue)
                .font(.headline).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.4).allowsTightening(true)
                .frame(width: max(0, diameter - 16), height: max(0, diameter * 0.5))
            }
            .overlay(alignment: .bottom) {
                Text(content.letter)
                    .font(.title3.weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: diameter * 0.42, height: diameter * 0.32)
                    .offset(y: 2)
            }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(content.title). \(value.remaining == nil ? "Остаток неизвестен" : "\(value.calorieLabel): \(value.ringRemainingValue) \(content == .calories ? "килокалорий" : "граммов")")")
    }

    private func macro(_ title: String, _ value: WidgetNutrient) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Text(title)
                Spacer(minLength: 0)
                Text(value.compactMacroValue + " г").monospacedDigit()
            }.font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            GeometryReader { geometry in
                Capsule().fill(.primary.opacity(0.22))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.primary).frame(width: geometry.size.width * value.progress)
                    }
            }.frame(height: 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value.macroValue)\(value.missing > 0 ? ". Часть значений неизвестна" : "")")
    }
}

/// Keeps the existing bar spacing with the user-selected optical translation.
/// The ring and all macro rows move together.
private struct NutritionCompositionLayout: Layout {
    let ringWidth: CGFloat
    let columnGap: CGFloat
    let margins: EdgeInsets
    let barHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let macroWidth = max(0, bounds.width - ringWidth - columnGap)
        let rowProposal = ProposedViewSize(width: macroWidth, height: nil)
        let rowHeights = (1...3).map { subviews[$0].sizeThatFits(rowProposal).height }
        let fullHeight = bounds.height + margins.top + margins.bottom
        let gap = max(0, (fullHeight - 3 * barHeight) / 4)
        let shift: CGFloat = 7
        subviews[0].place(at: CGPoint(x: bounds.minX + ringWidth / 2,
                                     y: bounds.midY + shift), anchor: .center,
                          proposal: ProposedViewSize(width: ringWidth, height: ringWidth))
        for index in 0..<3 {
            let barCenter = gap + barHeight / 2 + CGFloat(index) * (gap + barHeight) - margins.top
            subviews[index + 1].place(
                at: CGPoint(x: bounds.minX + ringWidth + columnGap,
                            y: bounds.minY + barCenter + shift - rowHeights[index] + barHeight / 2),
                anchor: .topLeading, proposal: rowProposal)
        }
    }
}

struct RecordingWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            VStack(spacing: 16) {
                HStack {
                    Label("Диктовка еды", systemImage: "mic.fill").foregroundStyle(.red)
                    Spacer()
                    timer(context.attributes)
                }
                actions(context.attributes)
            }
            .padding(16)
            .foregroundStyle(.white)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Запись", systemImage: "mic.fill").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) { timer(context.attributes) }
                DynamicIslandExpandedRegion(.bottom) {
                    actions(context.attributes).padding(.top, 12)
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            } compactTrailing: {
                timer(context.attributes).frame(width: 44)
            } minimal: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            }
            .keylineTint(.red)
        }
    }
    private func timer(_ attributes: RecordingActivityAttributes) -> some View {
        Text(attributes.startedAt, style: .timer)
            .monospacedDigit().font(.subheadline).foregroundStyle(.white)
    }
    private func actions(_ attributes: RecordingActivityAttributes) -> some View {
        HStack(spacing: 12) {
            Button(intent: CancelMealRecordingIntent(recordingID: attributes.recordingID)) {
                Label("Отменить", systemImage: "xmark").frame(maxWidth: .infinity)
            }.tint(.gray)
            Button(intent: FinishMealRecordingIntent(recordingID: attributes.recordingID)) {
                Label("Завершить", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }.tint(.red)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .font(.subheadline.weight(.semibold))
    }
}
