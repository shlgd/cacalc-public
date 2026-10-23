import SwiftUI

struct ProfileView: View {
    @AppStorage("planner.intervalHours") private var intervalHours = 4.0
    @AppStorage("planner.bedtimeHour") private var bedtimeHour = 23
    @AppStorage("usageArchiveError") private var usageArchiveError = ""
    @AppStorage("mealAnimationTesting") private var animationTesting = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(DiaryStore.self) private var store
    @State private var calories = ""
    @State private var protein = ""
    @State private var fat = ""
    @State private var carbs = ""
    @State private var saved = false
    @AppStorage("goals.linkCarbs") private var linkCarbs = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    target("Калории", suffix: "ккал", value: $calories, id: "goalCalories")
                    target("Белки", suffix: "г", value: $protein, id: "goalProtein")
                    target("Жиры", suffix: "г", value: $fat, id: "goalFat")
                    Toggle("Рассчитывать углеводы из калорий", isOn: $linkCarbs)
                    if linkCarbs {
                        LabeledContent("Углеводы", value: linkedCarbs.map { Numbers.display($0) + " г" } ?? "Проверьте цели")
                        if linkedCarbs == nil {
                            Text("Калорий должно хватать на указанные белки и жиры.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        target("Углеводы", suffix: "г", value: $carbs, id: "goalCarbs")
                        if let difference = goalDifference, abs(difference) >= 1 {
                            Text("По БЖУ получается на " + Numbers.display(abs(difference), places: 0) + " ккал " + (difference > 0 ? "больше" : "меньше") + ". Можно связать цели переключателем выше.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button(saved ? "Цели сохранены" : "Сохранить цели") { UsageTelemetry.shared.action("ProfileView.button.20");
                        store.perform {
                            let goals = Nutrition(calories: try Numbers.parse(calories, positive: true),
                                protein: try Numbers.parse(protein, positive: true), fat: try Numbers.parse(fat, positive: true), carbs: try resolvedCarbs())
                            try store.setGoals(goals); saved = true
                            hideKeyboard()
                        }
                    }.fontWeight(.semibold).accessibilityIdentifier("saveGoals")
                } header: { Text("Дневные цели") } footer: {
                    Text("Задайте свои цели КБЖУ. Изменения действуют с сегодняшнего дня; цели прошлых дней сохраняются.")
                }
                Section {
                    Stepper("Между приёмами · " + String(format: "%.1f", intervalHours) + " ч", value: $intervalHours, in: 2...6, step: 0.5)
                        .onChange(of: intervalHours) { _, _ in UsageTelemetry.shared.action("Planner.interval") }
                    Stepper("Сон примерно в \(bedtimeHour):00", value: $bedtimeHour, in: 18...23)
                        .onChange(of: bedtimeHour) { _, _ in UsageTelemetry.shared.action("Planner.bedtime") }
                } header: { Text("Ритм питания") } footer: {
                    Text("Время подстраивается по последним 28 дням с записями еды. Пока истории мало, используются стартовые окна. Подсказки КБЖУ пересчитываются по остатку дня и не меняют цели. Перекус можно записать в любое время.")
                }
                Section("Здоровье") {
                    NavigationLink { BodyMeasurementsView() } label: { Label("Вес и измерения", systemImage: "scalemass") }
                    NavigationLink { HealthDataView() } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Сон и активность", systemImage: "heart.text.clipboard")
                            if let steps = HealthSleep.shared.steps {
                                Text("Сегодня \(Int(steps)) шагов · сон и тренировки")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Голосовой ввод") {
                    Toggle("Тест анимации без распознавания", isOn: $animationTesting)
                    if animationTesting {
                        Text("Микрофон работает, модель не готовится. Продукты из речи не добавляются. Выключите для обычной диктовки.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    NavigationLink("Старые диктовки · Polza") { MealAPISettings() }
                }
                Section("О приложении") {
                    if !usageArchiveError.isEmpty {
                        Text("Не удалось сохранить журнал действий: " + usageArchiveError).foregroundStyle(.orange)
                    }
                    LabeledContent("Версия", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                    Label("Дневник хранится на iPhone", systemImage: "iphone")
                    Text("Каталог доступен без интернета. Наличие продукта и точность карточки зависят от данных источника.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Matvaretabellen · Norwegian Food Safety Authority · NLOD").font(.caption)
                    Link("Об источнике данных", destination: URL(string: "https://www.matvaretabellen.no/api/")!)
                    Link("Лицензия и происхождение данных", destination: URL(string: "https://data.norge.no/en/datasets/9d082918-e3d4-4ae2-8efd-e7d025dfd52d/matvaretabellen")!)
                    Text("Parakeet распознаёт речь на iPhone. Еду и количество выделяет локальный разбор; КБЖУ этикетки тоже разбираются на iPhone. Polza нужен только для прежних сохранённых диктовок.")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("Модели и лицензии библиотек") { ThirdPartyNoticesView() }
                }
            }.usageScroll("ProfileView.scroll.14").navigationTitle("Профиль").scrollDismissesKeyboard(.interactively)
                .scrollEdgeEffectHidden(true, for: .bottom)
                .toolbarBackground(.hidden, for: .tabBar)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Готово") { UsageTelemetry.shared.action("ProfileView.button.57"); hideKeyboard() }.accessibilityIdentifier("dismissKeyboard")
                    }
                }
                .onAppear { loadGoals() }
                .onChange(of: linkCarbs) { _, _ in saved = false; UsageTelemetry.shared.action("ProfileView.linkGoals") }
                .onChange(of: animationTesting) { _, value in UsageTelemetry.shared.event("animationTestingChanged", ["enabled": String(value)]) }
                .onChange(of: [calories, protein, fat, carbs]) { _, _ in saved = false }
        }
    }
    @ViewBuilder private func target(_ title: String, suffix: String, value: Binding<String>, id: String) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                HStack {
                    TextField("Не задано", text: value).keyboardType(.decimalPad).accessibilityIdentifier(id)
                    Text(suffix).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                Text(title)
                Spacer()
                TextField("Не задано", text: value).multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                    .accessibilityIdentifier(id).frame(minWidth: 90)
                Text(suffix).foregroundStyle(.secondary)
            }
        }
    }
    private var linkedCarbs: Decimal? {
        guard let energy = try? Numbers.parse(calories, positive: true),
              let p = try? Numbers.parse(protein, positive: true), let f = try? Numbers.parse(fat, positive: true) else { return nil }
        let result = (energy - 4 * p - 9 * f) / 4
        return result > 0 ? result : nil
    }
    private func resolvedCarbs() throws -> Decimal {
        if linkCarbs {
            guard let result = linkedCarbs else { throw FoodError.database("Проверьте калории, белки и жиры: для углеводов не осталось энергии.") }
            return result
        }
        return try Numbers.parse(carbs, positive: true)
    }
    private var goalDifference: Decimal? {
        guard let energy = try? Numbers.parse(calories, positive: true),
              let p = try? Numbers.parse(protein, positive: true), let f = try? Numbers.parse(fat, positive: true),
              let c = try? Numbers.parse(carbs, positive: true) else { return nil }
        return 4 * p + 9 * f + 4 * c - energy
    }
    private func loadGoals() {
        if let goals = store.currentGoals {
            calories = Numbers.string(goals.calories); protein = Numbers.string(goals.protein)
            fat = Numbers.string(goals.fat); carbs = Numbers.string(goals.carbs)
        }
    }
    private func hideKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
}

private struct ThirdPartyNoticesView: View {
    @State private var text = ""
    var body: some View {
        UsageScreen("ThirdPartyNoticesView") {
        ScrollView { Text(text).font(.footnote).textSelection(.enabled).padding() }.usageScroll("ProfileView.scroll.97")
            .navigationTitle("Лицензии").navigationBarTitleDisplayMode(.inline)
            .task {
                guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return }
                text = (try? String(contentsOf: url, encoding: .utf8)) ?? "Не удалось прочитать лицензии."
            }
            }
}
}
