import SwiftUI

@main struct CacalcApp: App {
    @State private var store: DiaryStore?
    @State private var library: ProductLibrary?
    @State private var mealSession: MealSession?
    @State private var startupError: String?
    @State private var storageStatus = "Идёт замер занятого места. Данные не удаляются."
    init() {
        if StorageUsageProbe.enabled || StorageMaintenance.enabled { return } // No database initialization or ASR during the scan.
        do { try StorageMaintenance.boundColdCache(home: URL(fileURLWithPath: NSHomeDirectory())) }
        catch { UserDefaults.standard.set(error.localizedDescription, forKey: "storageMaintenanceError") }
        // End the explicitly requested animation-only trial once, keeping later user choices.
        let preferences = UserDefaults.standard
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--asr-use-cpu") { preferences.set(true, forKey: "speechCPUTrial") }
        if ProcessInfo.processInfo.arguments.contains("--asr-use-ne") { preferences.set(false, forKey: "speechCPUTrial") }
        #endif
        if !preferences.bool(forKey: "liveRecognitionRestored235") {
            preferences.set(false, forKey: "mealAnimationTesting")
            preferences.set(true, forKey: "liveRecognitionRestored235")
        }
        do {
            let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            var testURL: URL?
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--meal-ui-testing"),
               let run = ProcessInfo.processInfo.environment["CACALC_TEST_RUN"], UUID(uuidString: run) != nil {
                testURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("UITests/\(run).store")
            }
            #endif
            #if DEBUG
            let resetHistory = !testing && testURL == nil && ProcessInfo.processInfo.arguments.contains("--reset-history-2026-09-15")
            if resetHistory {
                let location = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("default.store")
                _ = try HistoryReset.backupStore(at: location)
            }
            #endif
            let container = try DiaryStore.makeContainer(memory: testing, url: testURL)
            #if DEBUG
            if resetHistory { try HistoryReset.apply(to: container) }
            #endif
            if !testing && testURL == nil { try CatalogReset.apply(to: container) }
            if !testing && testURL == nil && ProcessInfo.processInfo.arguments.contains(CreamTableImport.launchArgument) {
                _ = try CreamTableImport.apply(to: container)
            }
            let catalog = Catalog(url: Bundle.main.url(forResource: "catalog", withExtension: "sqlite"))
            let diary = DiaryStore(container: container, catalog: catalog)
            diary.publishesWidget = !testing && testURL == nil

            _store = State(initialValue: diary)
            #if DEBUG
            if (testing || testURL != nil), let fixture = ProcessInfo.processInfo.environment["CACALC_TEST_MEAL_OUTPUT"] {
                let api = MealAPI(transport: { request in
                    try await Task.sleep(for: .milliseconds(100))
                    let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": fixture]]]])
                    return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
                _mealSession = State(initialValue: MealSession(store: diary, api: api, keyProvider: { "synthetic-ui-key" }))
            } else if testing || testURL != nil {
                _mealSession = State(initialValue: MealSession(store: diary, keyProvider: { nil }))
            } else { _mealSession = State(initialValue: MealSession(store: diary)) }
            #else
            _mealSession = State(initialValue: MealSession(store: diary))
            #endif
            _library = State(initialValue: ProductLibrary(container: container, catalog: catalog))
        } catch { _startupError = State(initialValue: error.localizedDescription) }
    }
    var body: some Scene {
        WindowGroup {
            if StorageMaintenance.enabled {
                Text(storageStatus).padding().task {
                    let previous = UIApplication.shared.isIdleTimerDisabled
                    UIApplication.shared.isIdleTimerDisabled = true
                    defer { UIApplication.shared.isIdleTimerDisabled = previous }
                    storageStatus = await StorageMaintenance.run()
                }
            } else if StorageUsageProbe.enabled {
                Text(storageStatus).padding().task {
                    let previous = UIApplication.shared.isIdleTimerDisabled
                    UIApplication.shared.isIdleTimerDisabled = true
                    defer { UIApplication.shared.isIdleTimerDisabled = previous }
                    if let report = await StorageUsageProbe.run() {
                        storageStatus = report.complete ? "Замер завершён. Отчёт сохранён." : "Замер неполный. Прогресс сохранён."
                    } else { storageStatus = "Не удалось сохранить отчёт замера." }
                }
            } else if let store, let library, let mealSession {
                RootView().modifier(UsageInputEvents()).environment(store).environment(library).environment(mealSession)
                    .task {
                        #if DEBUG
                        if SearchStartupProbe.enabled { await SearchStartupProbe.run(); return }
                        if VoiceStartupProbe.enabled { await VoiceStartupProbe.run(); return }
                        #endif
                        await store.reloadAsync()
                        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                              !ProcessInfo.processInfo.arguments.contains("--meal-ui-testing") else { return }
                        VoiceSession.mealVoice.prepareMealSpeech()
                        await MealRecordingActivity.shared.removeStale()
                        await VoiceSession.mealVoice.waitForSpeechPreparation()
                        #if DEBUG
                        if SearchStartupProbe.enabled || VoiceStartupProbe.enabled { return }
                        #endif
                        do {
                            let index = try await store.productRepository.searchIndex(store.catalog)
                            await SemanticProductSearch.shared.warmUp(products: index.products)
                        } catch {
                            mealSession.log("modelWarmupFailed", fields: ["model": "food-search", "error": error.localizedDescription])
                        }
                    }
                    .environment(\.locale, Locale(identifier: "ru_RU")).tint(.green)
            }
            else {
                ContentUnavailableView("Не удалось открыть дневник", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("Данные не удалены. Перезапустите приложение.\n\(startupError ?? "")"))
            }
        }
    }
}

// Date remains plain text: press feedback changes geometry, never color or opacity.
private struct DatePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? (reduceMotion ? 0.98 : 0.94) : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.65),
                       value: configuration.isPressed)
    }
}

enum AppTab: Hashable { case dishes, products, diary, profile }

struct RootView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(MealSession.self) private var meal
    @Environment(ProductLibrary.self) private var library
    var body: some View {
        MealScreenNavigation(showing: Binding(get: { meal.showing }, set: { meal.showing = $0 }), saving: meal.saving,
            root: MainTabsView().environment(store).environment(meal).environment(library)
                .environment(\.locale, Locale(identifier: "ru_RU")).tint(.green),
            destination: NavigationStack { MealEntryView() }
                .environment(store).environment(meal).environment(library)
                .environment(\.locale, Locale(identifier: "ru_RU")).tint(.green))
            .ignoresSafeArea()
    }
}

struct MainTabsView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(MealSession.self) private var mealSession
    @Environment(ProductLibrary.self) private var library
    @Environment(\.scenePhase) private var phase
    @State private var tab: AppTab = .diary
    var body: some View {
        @Bindable var store = store
        @Bindable var mealSession = mealSession
        TabView(selection: $tab) {
            Tab("Блюда", systemImage: "fork.knife", value: .dishes) { PreparedFoodView() }
            Tab("Продукты", systemImage: "carrot", value: .products) { ProductsView() }
            Tab("Дневник", systemImage: "book.closed", value: .diary) {
                DiaryView { tab = .profile }
            }
            Tab("Профиль", systemImage: "person.crop.circle", value: .profile) {
                ProfileView()
            }
        }
        .onChange(of: tab, initial: true) { _, value in UsageTelemetry.shared.tab(String(describing: value)) }
        .onOpenURL { url in
            guard url.scheme == "cacalc", url.host == "diary" else { return }
            tab = .diary
            store.refreshClock()
            store.select(store.today)
        }
        .onChange(of: store.selectedDay) { _, value in UsageTelemetry.shared.event("daySelected", ["day": value.rawValue]) }
        .onChange(of: phase, initial: true) { _, value in UsageTelemetry.shared.phase(value) }
        .sensoryFeedback(.success, trigger: store.savedCount)
        .sheet(isPresented: $store.isShowingFood) { FoodSheet().environment(store) }
        .onChange(of: mealSession.showing) { _, showing in
            if showing { tab = .diary }
            else { Task { await mealSession.dismissed() } }
        }
        .sheet(isPresented: Binding(get: { library.showingEditor && !mealSession.showing }, set: {
            if !$0 && !mealSession.showing { library.showingEditor = false }
        })) { ProductEditor().environment(library).environment(store) }
        .task { await mealSession.load() }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: {
            (store.error != nil && !store.isShowingFood) || (mealSession.error != nil && !mealSession.showing)
        }, set: { if !$0 { store.error = nil; mealSession.error = nil } })) {
            Button("Понятно", role: .cancel) { UsageTelemetry.shared.action("CacalcApp.button.160"); store.error = nil; mealSession.error = nil }
        } message: { Text(mealSession.error ?? store.error ?? "") }
        .onChange(of: phase) { _, newValue in if newValue == .active { store.refreshClock() } }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await mealSession.backupDaily()
                let next = Calendar.autoupdatingCurrent.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 1), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
                do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow))) } catch { return }
                store.refreshClock()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in store.refreshClock() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in store.refreshClock() }
    }
}

struct DiaryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DiaryStore.self) private var store
    @Environment(MealSession.self) private var mealSession
    @State private var streakOpen = false
    @State private var measurementsOpen = false
    @State private var latestWeight: BodyMeasurement?
    @State private var scrollEdge = DiaryScrollEdge()
    let showProfile: () -> Void
    private func reloadWeight() {
        do { latestWeight = try MeasurementRepository(container: store.container).all().first { $0.kind == .weight } }
        catch { latestWeight = nil; store.error = "Не удалось прочитать последнее измерение веса." }
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                DiaryPager(store: store, mealSession: mealSession, scrollEdge: scrollEdge, showProfile: showProfile,
                           selectedDay: store.selectedDay, revision: store.pageRevision,
                           items: store.items, goals: store.goals,
                           topInset: geometry.safeAreaInsets.top + 76,
                           bottomInset: geometry.safeAreaInsets.bottom + 24)
                    .ignoresSafeArea(.container, edges: .vertical)

            }
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay(alignment: .top) {
                DiaryHeaderHost(scrollEdge: scrollEdge) {
                HStack(alignment: .center, spacing: 16) {
                    Button { UsageTelemetry.shared.action("CacalcApp.button.199");
                        guard store.selectedDay != store.today else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            store.select(store.today)
                        }
                    } label: {
                        Text(store.selectedDay.title(relativeTo: store.today))
                            .font(.title2.weight(.bold)).foregroundStyle(Color(uiColor: .label))
                            .multilineTextAlignment(.leading)
                            .accessibilityIdentifier("diaryDate")
                            .accessibilityValue(store.selectedDay.rawValue)
                            .accessibilityAddTraits(.isHeader)
                    }.buttonStyle(DatePressStyle())
                        .accessibilityIdentifier("returnToday")
                        .accessibilityLabel(store.selectedDay.title(relativeTo: store.today))
                        .accessibilityValue(store.selectedDay.rawValue)
                        .accessibilityHint(store.selectedDay == store.today ? "" : "Вернуться к сегодняшнему дню")
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Button { UsageTelemetry.shared.action("Diary.measurements"); measurementsOpen = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "scalemass").font(.system(size: 16, weight: .medium))
                                Text(latestWeight.map { Numbers.display($0.value, places: 2) + " кг" } ?? "Вес")
                                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                            }
                            .foregroundStyle(Color(uiColor: .label))
                            .padding(.leading, 16).padding(.trailing, 16).frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(latestWeight.map { "Последний вес: " + Numbers.display($0.value, places: 2) + " килограммов" } ?? "Записать вес")
                            .accessibilityHint("Открыть запись веса и талии")
                        Button { UsageTelemetry.shared.action("CacalcApp.button.217"); streakOpen = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "flame.fill").foregroundStyle(.orange)
                                    .font(.system(size: 20, weight: .semibold))
                                Text("\(store.streak)").font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color(uiColor: .label))
                            }
                            .monospacedDigit()
                            .padding(.leading, 16).padding(.trailing, 16).frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Серия: \(store.streak) дней подряд")
                            .accessibilityHint("Открыть календарь дневника")
                            .accessibilityIdentifier("streak")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }.padding(.horizontal, 20).padding(.top, 8)
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { HealthSleep.shared.pauseArchive(); return }
                reloadWeight()
                await HealthSleep.shared.refresh()
            }
            .onAppear { reloadWeight() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { HealthSleep.shared.pauseArchive() }
            }
            .sheet(isPresented: $measurementsOpen, onDismiss: { reloadWeight() }) { QuickMeasurementsView() }
            .usagePresentation("calendar", visible: streakOpen)
            .sheet(isPresented: $streakOpen) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Серия: \(store.streak)", systemImage: "flame.fill")
                            .font(.title2.weight(.semibold)).foregroundStyle(.orange)
                        DatePicker("Дата дневника", selection: Binding(
                            get: { store.selectedDay.date },
                            set: { store.select(Day($0)) }
                        ), displayedComponents: .date)
                        .datePickerStyle(.graphical).accessibilityIdentifier("diaryCalendar")
                        Text("Каждый день хотя бы с одной записью продолжает серию. Если сегодня записей ещё нет, сохраняется серия до вчерашнего дня.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(20)
                        .navigationTitle("Календарь").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Сегодня") { UsageTelemetry.shared.action("CacalcApp.button.250"); store.select(store.today); streakOpen = false }
                                    .accessibilityIdentifier("calendarToday")
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Готово") { UsageTelemetry.shared.action("CacalcApp.button.254"); streakOpen = false }
                            }
                        }
                }.presentationDetents([.large])
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .tabBar)



        }
    }
}

private enum DiarySummaryExperiment {
    // Flip to false to restore the preserved build-340 summary without touching diary data.
    static let usesFourRings = true
}

struct DiaryPage: View {
    @ScaledMetric(relativeTo: .headline) private var entryActionGap = 20.0
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DiaryStore.self) private var store
    @Environment(MealSession.self) private var mealSession
    @AppStorage("planner.intervalHours") private var intervalHours = 4.0
    @AppStorage("planner.bedtimeHour") private var bedtimeHour = 23
    @State private var expanded: Set<String> = []
    let day: Day
    let data: DiaryPageData
    let showProfile: () -> Void
    let topInset: CGFloat
    let bottomInset: CGFloat
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summary
                if data.issues.isEmpty && !store.readIssues.isEmpty {
                    Label("Часть истории не прочитана. Данные сохранены; серия может быть неполной.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(data.issues) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(spacing: 0) {
                    plannerCard
                    DiaryEntryActionButton(day: day)
                        .padding(.vertical, entryActionGap)
                        .overlay(alignment: .bottomLeading) {
                            if !consumedItems.isEmpty {
                                recordsHeading.padding(.bottom, 4)
                            }
                        }
                    if !consumedItems.isEmpty {
                        consumedList
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, bottomInset)
        }.usageScroll("CacalcApp.scroll.283")
        .safeAreaBar(edge: .top, spacing: 0) {
            Color.clear.frame(height: max(0, topInset - 8))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .scrollClipDisabled()
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityAction(named: "Предыдущий день") { store.select(day.offset(-1)) }
        .accessibilityAction(named: "Следующий день") { store.select(day.offset(1)) }
    }
    private var recordsHeading: some View {
        Text("Записи").font(.caption.weight(.semibold)).padding(.leading, 4)
    }
    @ViewBuilder private var summary: some View {
        if DiarySummaryExperiment.usesFourRings {
            ringSummary
        } else {
            legacySummary
        }
    }
    private var ringMetrics: [DiaryRingMetric] {
        [DiaryRingMetric(letter: "К", title: "Калории", unit: "ккал", color: .green,
                         value: WidgetNutrient(known: data.total.calories, target: data.goals?.calories, missing: data.summary.missingCalories)),
         DiaryRingMetric(letter: "Б", title: "Белки", unit: "г", color: .cyan,
                         value: WidgetNutrient(known: data.total.protein, target: data.goals?.protein, missing: data.summary.missingProtein)),
         DiaryRingMetric(letter: "Ж", title: "Жиры", unit: "г", color: .orange,
                         value: WidgetNutrient(known: data.total.fat, target: data.goals?.fat, missing: data.summary.missingFat)),
         DiaryRingMetric(letter: "У", title: "Углеводы", unit: "г", color: .indigo,
                         value: WidgetNutrient(known: data.total.carbs, target: data.goals?.carbs, missing: data.summary.missingCarbs))]
    }
    private var ringSummary: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16),
                                 count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 16) {
            ForEach(ringMetrics) { metric in DiaryNutrientRing(metric: metric) }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diaryNutritionRings")
    }
    private var setGoalsButton: some View {
        Button("Задать цели КБЖУ") { UsageTelemetry.shared.action("CacalcApp.button.321");
            showProfile()
        }.buttonStyle(.glass(.regular.interactive())).accessibilityIdentifier("setGoals")
    }
    private var legacySummary: some View {
        VStack(spacing: 18) {
            CalorieRing(eaten: data.total.calories, target: data.goals?.calories, future: day > store.today,
                        complete: data.summary.missingCalories == 0)
            if data.summary.missingCalories > 0 {
                Text("Без калорий: \(data.summary.missingCalories). Точный остаток пока неизвестен.")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("incompleteCalories")
            }
            if data.goals == nil {
                setGoalsButton
            }
            if typeSize.isAccessibilitySize {
                VStack(spacing: 16) { macroIndicators }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { macroIndicators }
                    VStack(spacing: 16) { macroIndicators }
                }
            }
        }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 30))
    }
    @ViewBuilder private var macroIndicators: some View {
        MacroIndicator(title: "Белки", eaten: data.total.protein, target: data.goals?.protein, color: .cyan, missing: data.summary.missingProtein)
        MacroIndicator(title: "Жиры", eaten: data.total.fat, target: data.goals?.fat, color: .orange, missing: data.summary.missingFat)
        MacroIndicator(title: "Углеводы", eaten: data.total.carbs, target: data.goals?.carbs, color: .indigo, missing: data.summary.missingCarbs)
    }
    private var consumedItems: [DiaryItem] {
        data.items.filter { $0.row.timing?.isPlanned != true }
    }
    private var consumedList: some View {
        let meals = Meal.currentCases.filter { meal in consumedItems.contains { $0.meal == meal } }
        let snacks = DiaryEpisode.snacks(in: consumedItems)
        return VStack(spacing: 0) {
            ForEach(Array(meals.enumerated()), id: \.element) { index, meal in
                if index > 0 { Divider().padding(.horizontal, 16) }
                mealCard(meal, entries: consumedItems.filter { $0.meal == meal })
            }
            ForEach(Array(snacks.enumerated()), id: \.element.id) { index, episode in
                if !meals.isEmpty || index > 0 { Divider().padding(.horizontal, 16) }
                mealCard(.snack, entries: episode.entries,
                    title: snacks.count > 1 ? "Перекус \(index + 1)" : "Перекус",
                    cardID: "snack:" + episode.id)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
    private var plannerCard: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let plan = AdaptiveMealPlan.calculate(page: data, day: day, now: context.date,
                intervalHours: intervalHours, bedtimeHour: bedtimeHour, history: store.mealHistory, wakeTime: HealthSleep.shared.wake)
            let suggestions = day >= store.today ? plan.suggestions : []
            let plans = data.items.filter { $0.row.timing?.isPlanned == true }
            let plannedByMeal = Dictionary(grouping: plans, by: \.meal)
            let orderedMeals = (Meal.currentCases + [.snack]).filter { meal in
                suggestions.contains { $0.meal == meal } || plannedByMeal[meal] != nil
            }
            if !suggestions.isEmpty || !plans.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("План").font(.headline).padding(.leading, 4)
                VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(orderedMeals.enumerated()), id: \.element) { index, meal in
                    if index > 0 { Divider().padding(.horizontal, 16) }
                    if let suggestion = suggestions.first(where: { $0.meal == meal }) {
                        PlannerMealRow(suggestion: suggestion).padding(16)
                    }
                    let mealPlans = plannedByMeal[meal] ?? []
                    let plannedEpisodeIDs = Array(Set(mealPlans.compactMap { $0.row.timing?.episodeID }))
                        .sorted { first, second in
                            let a = mealPlans.filter { $0.row.timing?.episodeID == first }.compactMap { $0.row.timing?.selectedAt }.min() ?? .distantFuture
                            let b = mealPlans.filter { $0.row.timing?.episodeID == second }.compactMap { $0.row.timing?.selectedAt }.min() ?? .distantFuture
                            return a == b ? first.uuidString < second.uuidString : a < b
                        }
                ForEach(Array(plannedEpisodeIDs.enumerated()), id: \.element) { index, id in
                    let rows = mealPlans.filter { $0.row.timing?.episodeID == id }
                    if index > 0 {
                        Divider().padding(.horizontal, 16)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: rows.first?.meal.icon ?? "fork.knife").font(.title3).foregroundStyle(.green)
                            .frame(width: 40, height: 40)
                            .background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(rows.first?.meal.title ?? "Еда").font(.headline)
                                Spacer()
                                if let date = rows.first?.row.timing?.selectedAt {
                                    Text(date.formatted(date: .omitted, time: .shortened))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Text(rows.map { $0.row.displayName }.joined(separator: ", "))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Button("Съел сейчас") {
                                UsageTelemetry.shared.action("Planner.consume")
                                Task { await mealSession.consumePlanned(id) }
                            }.buttonStyle(.glass(.regular.interactive())).disabled(mealSession.saving)
                        }
                    }.padding(16)
                }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            }
            }
        }.task(id: plannerRevision) {
            guard !Task.isCancelled else { return }
            let plan = AdaptiveMealPlan.calculate(page: data, day: day, now: Date(), intervalHours: intervalHours, bedtimeHour: bedtimeHour, history: store.mealHistory, wakeTime: HealthSleep.shared.wake)
            mealSession.log("dayPlanCalculated", fields: ["ruleVersion": AdaptiveMealPlan.ruleVersion, "day": day.rawValue,
                "input": plannerRevision, "historyRows": String(store.mealHistory.count),
                "suggestions": String(data: (try? JSONEncoder().encode(plan.suggestions)) ?? Data(), encoding: .utf8) ?? ""])
        }
    }
    private var plannerRevision: String {
        // A semantic revision, not JSON whose object-key order can change in body.
        return day.rawValue + "|" + String(intervalHours) + "|" + String(bedtimeHour)
            + "|" + String(store.pageRevision) + "|" + TimeZone.autoupdatingCurrent.identifier
            + "|" + String(HealthSleep.shared.wake?.timeIntervalSince1970 ?? 0)
    }
    private func mealTimeLabel(_ entries: [DiaryItem]) -> String {
        let times = entries.filter { $0.row.timing?.isPlanned != true }.compactMap { $0.row.timing?.consumedAt }.sorted()
        guard let first = times.first else { return entries.allSatisfy { $0.row.timing?.isPlanned == true } ? "Запланировано" : "Время не указано" }
        let start = first.formatted(date: .omitted, time: .shortened)
        guard let last = times.last, last.timeIntervalSince(first) >= 300 else { return start }
        return start + "–" + last.formatted(date: .omitted, time: .shortened)
    }
    private func compactNutrition(_ value: NutritionSummary) -> String {
        func number(_ amount: Decimal, _ missing: Int) -> String { (missing > 0 ? "≥" : "") + Numbers.display(amount, places: 0) }
        return number(value.known.calories, value.missingCalories) + " ккал · Б " + number(value.known.protein, value.missingProtein) + " · Ж " + number(value.known.fat, value.missingFat) + " · У " + number(value.known.carbs, value.missingCarbs)
    }
    private func mealCard(_ meal: Meal, entries suppliedEntries: [DiaryItem]? = nil,
                          title: String? = nil, cardID suppliedCardID: String? = nil) -> some View {
        let entries = suppliedEntries ?? data.items.filter { $0.meal == meal }
        let cardID = suppliedCardID ?? "meal:" + meal.rawValue
        let accessibilityID = suppliedCardID.map { "meal_" + $0 } ?? "meal_" + meal.rawValue
        let summary = NutritionSummary(entries.filter { $0.row.timing?.isPlanned != true }.map { $0.row.portion })
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { UsageTelemetry.shared.action("CacalcApp.button.346");
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                        if expanded.contains(cardID) { expanded.remove(cardID) } else { expanded.insert(cardID) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: meal.icon).font(.title3).foregroundStyle(.green)
                            .frame(width: 40, height: 40).background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(title ?? meal.title).font(.headline).foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Text(mealTimeLabel(entries)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(compactNutrition(summary)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: expanded.contains(cardID) ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier(accessibilityID)
            }.padding(16)
            if expanded.contains(cardID) {
                Divider().padding(.horizontal, 16)
                Menu {
                    Button { UsageTelemetry.shared.action("CacalcApp.button.363")
                        Task { await mealSession.begin(day: day, meal: meal) }
                    } label: { Label("Добавить ещё", systemImage: "plus") }
                    Menu {
                        ForEach(Meal.allCases) { destination in
                            Button { UsageTelemetry.shared.action("Diary.mealType.change")
                                Task { await mealSession.reassignMeal(entries, to: destination) }
                            } label: {
                                Label(destination.title, systemImage: destination == meal ? "checkmark" : destination.icon)
                            }
                            .disabled(destination == meal || mealSession.saving)
                        }
                    } label: { Label("Перенести в", systemImage: "arrow.right") }
                    Section("Изменить продукт") {
                        ForEach(entries) { entry in
                            Button(entry.row.displayName) { UsageTelemetry.shared.action("CacalcApp.button.375")
                                Task { await mealSession.begin(day: day, item: entry) }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Изменить или добавить").font(.subheadline.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.down").font(.caption)
                    }.padding(16).contentShape(Rectangle())
                }
                ForEach(entries) { entry in
                    Divider().padding(.horizontal, 16)
                    MealHistoryFoodRow(row: entry.row).padding(.horizontal, 16).padding(.vertical, 12)
                        .accessibilityIdentifier("entry_\(entry.id)")
                }
            }
        }
    }
}


private struct PlannerMealRow: View {
    let suggestion: AdaptiveMealPlan.Suggestion
    private var timeRange: String {
        suggestion.start.formatted(date: .omitted, time: .shortened)
            + "–"
            + suggestion.end.formatted(date: .omitted, time: .shortened)
    }
    private func value(_ amount: Decimal?) -> String {
        amount.map { Numbers.display($0, places: 0) } ?? "—"
    }
    private var nutritionAccessibility: String {
        let nutrition = suggestion.nutrition
        func spoken(_ amount: Decimal?, _ unit: String) -> String {
            amount.map { "примерно " + Numbers.display($0, places: 0) + " " + unit } ?? "неизвестно"
        }
        return "Калории: " + spoken(nutrition.calories, "килокалорий")
            + ", белки: " + spoken(nutrition.protein, "граммов")
            + ", жиры: " + spoken(nutrition.fat, "граммов")
            + ", углеводы: " + spoken(nutrition.carbs, "граммов")
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                identity
                nutritionLine.fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 8) {
                identity
                nutritionGrid
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(suggestion.meal.title + ", " + timeRange + ", " + nutritionAccessibility)
    }
    private var identity: some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.meal.icon).font(.title3).foregroundStyle(.green)
                .frame(width: 40, height: 40).background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) { title; time }
        }
    }
    private var nutritionGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow { calories; protein }
            GridRow { fat; carbs }
        }
    }
    private var nutritionLine: some View {
        HStack(spacing: 12) { calories; protein; fat; carbs }
    }
    private var title: some View { Text(suggestion.meal.title).font(.headline).fixedSize() }
    private var time: some View {
        Text(timeRange).font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
    }
    private var calories: some View { macro("К", suggestion.nutrition.calories) }
    private var protein: some View { macro("Б", suggestion.nutrition.protein) }
    private var fat: some View { macro("Ж", suggestion.nutrition.fat) }
    private var carbs: some View { macro("У", suggestion.nutrition.carbs) }
    private func macro(_ letter: String, _ amount: Decimal?) -> some View {
        Text(letter + " " + value(amount)).font(.caption).foregroundStyle(.secondary)
            .monospacedDigit().fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor final class DiaryScrollEdge {
    let interaction = UIScrollEdgeElementContainerInteraction()
    var activeDay = Day(Date())
    init() { interaction.edge = .top }
    func connect(_ scrollView: UIScrollView, day: Day) {
        guard day == activeDay else { return }
        guard interaction.scrollView !== scrollView else { return }
        scrollView.topEdgeEffect.style = .soft
        scrollView.topEdgeEffect.isHidden = false
        interaction.scrollView = scrollView
    }
}

struct DiaryHeaderHost<Content: View>: UIViewControllerRepresentable {
    let scrollEdge: DiaryScrollEdge
    @ViewBuilder var content: () -> Content
    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content())
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.view.addInteraction(scrollEdge.interaction)
        return controller
    }
    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        controller.rootView = content()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIHostingController<Content>, context: Context) -> CGSize? {
        uiViewController.sizeThatFits(in: CGSize(width: proposal.width ?? 390, height: .greatestFiniteMagnitude))
    }
}

// UIKit owns the continuous drag, cancellation, velocity and snap to a full page.
struct DiaryPager: UIViewControllerRepresentable {
    var store: DiaryStore
    var mealSession: MealSession
    var scrollEdge: DiaryScrollEdge
    var showProfile: () -> Void
    var selectedDay: Day
    var revision: Int
    var items: [DiaryItem]
    var goals: Nutrition?
    var topInset: CGFloat
    var bottomInset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .systemGroupedBackground
        controller.setViewControllers([context.coordinator.makePage(selectedDay)], direction: .forward, animated: false)
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.showSelectedDay(in: controller)
    }
    final class PageController: UIHostingController<AnyView> {
        let day: Day
        let scrollEdge: DiaryScrollEdge
        var revision = -1
        var contentInsets: CGSize = .zero
        private weak var connectedScroll: UIScrollView?
        func invalidateScrollConnection() { connectedScroll = nil }
        init(day: Day, scrollEdge: DiaryScrollEdge, rootView: AnyView) {
            self.day = day
            self.scrollEdge = scrollEdge
            super.init(rootView: rootView)
            safeAreaRegions = []
            view.backgroundColor = .systemGroupedBackground
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            connectScrollEdge()
        }
        func connectScrollEdge() {
            guard day == scrollEdge.activeDay else { return }
            if let connectedScroll { scrollEdge.connect(connectedScroll, day: day); return }
            func findScroll(in view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView { return scroll }
                return view.subviews.lazy.compactMap { findScroll(in: $0) }.first
            }
            if let scroll = findScroll(in: view) {
                connectedScroll = scroll
                scrollEdge.connect(scroll, day: day)
            }
        }
        @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }
    }
    @MainActor final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: DiaryPager
        var transitioning = false
        private var pages: [Day: PageController] = [:]
        init(_ parent: DiaryPager) { self.parent = parent }
        func showSelectedDay(in controller: UIPageViewController) {
            guard !transitioning else { return }
            let selectedDay = parent.selectedDay
            parent.scrollEdge.activeDay = selectedDay
            let current = controller.viewControllers?.first as? PageController
            if let current, current.day == selectedDay {
                refresh(current)
                current.connectScrollEdge()
                return
            }
            let direction: UIPageViewController.NavigationDirection =
                current.map { selectedDay < $0.day } == true ? .reverse : .forward
            let page = makePage(selectedDay)
            transitioning = true
            controller.view.isUserInteractionEnabled = false
            // Use the same native horizontal transition as a swipe, even across several days.
            controller.setViewControllers([page], direction: direction,
                                          animated: !UIAccessibility.isReduceMotionEnabled) { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.transitioning = false
                controller.view.isUserInteractionEnabled = true
                page.connectScrollEdge()
                // Apply a newer selection/data update received while the animation was running.
                self.showSelectedDay(in: controller)
            }
        }
        func content(_ day: Day) -> AnyView {
            do {
                let data = try parent.store.presentationPage(for: day)
                return AnyView(DiaryPage(day: day, data: data, showProfile: parent.showProfile, topInset: parent.topInset, bottomInset: parent.bottomInset)
                    .environment(parent.store).environment(parent.mealSession).environment(\.locale, Locale(identifier: "ru_RU")).tint(.green))
            } catch {
                return AnyView(ContentUnavailableView("Не удалось открыть день", systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)))
            }
        }
        func refresh(_ page: PageController) {
            let insets = CGSize(width: parent.topInset, height: parent.bottomInset)
            guard page.revision != parent.revision || page.contentInsets != insets else { return }
            page.rootView = content(page.day)
            page.invalidateScrollConnection()
            page.revision = parent.revision
            page.contentInsets = insets
        }
        func makePage(_ day: Day) -> PageController {
            if let cached = pages[day] { refresh(cached); return cached }
            let page = PageController(day: day, scrollEdge: parent.scrollEdge, rootView: content(day))
            page.revision = parent.revision
            page.contentInsets = CGSize(width: parent.topInset, height: parent.bottomInset)
            pages = pages.filter { $0.key >= day.offset(-1) && $0.key <= day.offset(1) }
            pages[day] = page
            return page
        }
        // Chronological pages: a right-to-left swipe reveals the next day.
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? PageController else { return nil }
            return makePage(page.day.offset(-1))
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? PageController else { return nil }
            return makePage(page.day.offset(1))
        }
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            transitioning = true
            for case let page as PageController in pendingViewControllers {
                refresh(page)
            }
        }
        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            guard completed, let page = controller.viewControllers?.first as? PageController else { return }
            parent.scrollEdge.activeDay = page.day
            page.connectScrollEdge()
            parent.store.select(page.day, usePresentationCache: true)
            if parent.store.selectedDay != page.day {
                controller.setViewControllers([makePage(parent.store.selectedDay)], direction: .forward, animated: false)
            }
        }
    }
}

private struct DiaryRingMetric: Identifiable {
    let letter: String
    let title: String
    let unit: String
    let color: Color
    let value: WidgetNutrient
    var id: String { letter }
}

private struct DiaryNutrientRing: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let metric: DiaryRingMetric
    private let arcFraction = 290.0 / 360.0
    private let startAngle = 125.0
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            // Removing 24 pt of padding and widening the gaps frees 3 pt per
            // column (10 pt in the two-column accessibility layout).
            let referenceSide = max(1, side - (typeSize.isAccessibilitySize ? 10 : 3))
            let labelDiameter = max(0, referenceSide - 8)
            let diameter = max(0, labelDiameter - 4)
            Circle().trim(from: 0, to: arcFraction)
                .stroke(metric.color.opacity(0.18), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(startAngle))
                .frame(width: diameter, height: diameter)
                .overlay {
                    Circle().trim(from: 0, to: arcFraction * metric.value.progress)
                        .stroke(metric.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(startAngle))
                }
                .overlay {
                    Text(metric.value.ringRemainingValue)
                        .font(.title2.weight(.bold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.4).allowsTightening(true)
                        .frame(width: max(0, labelDiameter - 16), height: max(0, labelDiameter * 0.5))
                }
                .overlay(alignment: .bottom) {
                    Text(metric.letter).font(.title3.weight(.bold)).foregroundStyle(metric.color)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: labelDiameter * 0.42, height: labelDiameter * 0.32).offset(y: 2)
                }
                .frame(width: referenceSide, height: referenceSide)
                .scaleEffect(side / referenceSide)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title): \(metric.value.remaining == nil ? "остаток неизвестен" : "\(metric.value.calorieLabel) \(metric.value.ringRemainingValue) \(metric.unit)")")
    }
}

struct CalorieRing: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let eaten: Decimal
    let target: Decimal?
    let future: Bool
    var complete = true
    private var budget: Budget { Budget(eaten: eaten, target: target) }
    private var valueLabels: some View {
        CalorieRingLabels(
            value: (complete ? "" : "≥ ") + Numbers.display(complete ? (budget.remainder ?? eaten) : eaten, places: 0),
            caption: !complete ? "Известно" : target == nil ? (future ? "В плане" : "Съедено") : (budget.exceeded ? "Сверх цели" : "Осталось"))
    }
    private var eatenTotal: some View {
        VStack(spacing: 5) {
            Text(Numbers.display(eaten, places: 0)).font(.title3.weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.65).accessibilityIdentifier("eatenValue")
            Text(future ? "Запланировано" : "Съедено").font(.caption).foregroundStyle(.secondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity)
    }
    private var goalTotal: some View {
        VStack(spacing: 5) {
            Text(target.map { Numbers.display($0, places: 0) } ?? "—").font(.title3.weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.65)
            Text("Цель").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
    private var ring: some View {
        CalorieRingGraphic(progress: budget.progress, exceeded: budget.exceeded) {
            valueLabels
        }.padding(5)
    }
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 16) { valueLabels; eatenTotal; goalTotal }
            } else {
                HStack(spacing: 6) { eatenTotal; ring; goalTotal }
            }
        }.monospacedDigit().frame(maxWidth: .infinity)
    }
}

struct MacroIndicator: View {
    let title: String
    let eaten: Decimal
    let target: Decimal?
    let color: Color
    var missing = 0
    var valueText: String? = nil
    var additionText: String? = nil
    var beforeEaten: Decimal? = nil
    var trackWidth: CGFloat? = nil
    var compactLayout = false
    var animatesValue = false
    var mealRecommendation: Decimal? = nil
    @ScaledMetric(relativeTo: .footnote) private var compactValueSize = 14
    private var budget: Budget { Budget(eaten: eaten, target: target) }
    private var formattedValue: Text {
        let base = valueText ?? ((missing > 0 ? "≥ " : "") + (target.map { "\(Numbers.display(eaten, places: 0)) / \(Numbers.display($0, places: 0)) г" } ?? "\(Numbers.display(eaten, places: 0)) г"))
        if let additionText {
            return Text("\(base) (\(additionText))")
        }
        return Text(base)
    }
    private var recommendationProgress: Double? {
        guard let beforeEaten, let mealRecommendation, let target, target > 0 else { return nil }
        return Budget(eaten: beforeEaten + mealRecommendation, target: target).progress
    }

    var body: some View {
        VStack(alignment: .center, spacing: beforeEaten != nil ? 5 : 7) {
            Text(title).font(.subheadline)
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Group {
                        if let beforeEaten {
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(uiColor: .systemGray4))
                                Capsule().fill(color.opacity(0.4))
                                    .frame(width: geometry.size.width * budget.progress)
                                Capsule().fill(color)
                                    .frame(width: geometry.size.width * Budget(eaten: beforeEaten, target: target).progress)
                            }
                        } else {
                            Capsule().fill(color.opacity(0.16))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(color)
                                        .frame(width: geometry.size.width * budget.progress)
                                }
                        }
                    }
                    .frame(height: 6)
                    .clipShape(Capsule())
                    if let recommendationProgress {
                        Capsule().fill(Color.primary.opacity(0.85))
                            .frame(width: 1.5, height: 4)
                            .offset(x: max(0, min(geometry.size.width - 1.5,
                                geometry.size.width * recommendationProgress - 0.75)))
                    }
                }
            }.frame(width: trackWidth, height: 6).accessibilityHidden(true)
            formattedValue
                .contentTransition(animatesValue ? .numericText() : .identity)
                .foregroundStyle(Color.primary)
                .font((compactLayout ? Font.system(size: compactValueSize) : Font.subheadline).weight(.semibold)).monospacedDigit().fixedSize(horizontal: false, vertical: true)

        }.frame(minWidth: compactLayout ? 0 : 74, maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityHint(missing > 0 ? "Значение неизвестно для \(missing) позиций" : "")
    }
}
