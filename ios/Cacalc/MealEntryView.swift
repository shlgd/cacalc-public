import SwiftUI
import AVFoundation

struct MealEntryView: View {
    @Environment(MealSession.self) private var meal
    @Environment(DiaryStore.self) private var store
    @Environment(ProductLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("planner.intervalHours") private var intervalHours = 4.0
    @AppStorage("planner.bedtimeHour") private var bedtimeHour = 23
    @State private var voice = VoiceSession.mealVoice
    @State private var page: DiaryPageData?
    @State private var query = ""
    @State private var searchError: String?
    @State private var found: [Product] = []
    @State private var unresolvedFood = ""
    @State private var toolbarFade = MealToolbarFade()
    @State private var scanner = false
    @State private var combinationToSave: FoodCombination?
    @State private var showingCombinations = false
    @State private var searching = false
    @State private var navigationBarHeight: CGFloat = 44
    @State private var recorderFrame: CGRect = .zero
    @State private var bottomControlWidth: CGFloat = 360
    @State private var startingVoice = false
    @State private var showingModelResponse = false
    @FocusState private var editingWeight: UUID?
    @State private var weightRowFrames: [UUID: CGRect] = [:]
    @State private var weightListFrame: CGRect = .zero
    @State private var weightKeyboardTop: CGFloat?
    @State private var weightEditingOrder: [UUID] = []
    @State private var quickRow: MealRow?
    @State private var matchingRow: MealRow?
    private var voiceActive: Bool { startingVoice || voice.capturing || voice.phase == .requesting || voice.processing }
    private var processing: Bool { meal.busy }
    private var showingLiveStatus: Bool { voiceActive || meal.liveProgress != nil }
    private var processingTitle: String { meal.processingTitle }
    private var locked: Bool { voice.locked || startingVoice || meal.busy || meal.saving }
    private var canSave: Bool {
        !locked && meal.canCommit
    }
    private func recommendation(for draft: MealDraft, page: DiaryPageData) -> PortionSnapshot? {
        guard draft.meal != .snack else { return nil }
        let openedAt = draft.timing?.startedAt ?? Date()
        return AdaptiveMealPlan.calculate(page: page, day: draft.day, now: openedAt,
            intervalHours: intervalHours, bedtimeHour: bedtimeHour,
            history: store.mealHistory, wakeTime: HealthSleep.shared.wake)
            .suggestions.first { $0.meal == draft.meal }?.nutrition
    }
    private struct DisplayRow: Identifiable {
        var row: MealRow
        var pending: Bool
        var id: UUID { row.id }
    }
    private var displayRows: [DisplayRow] {
        let ranked = showingLiveStatus ? (meal.draft?.rows ?? []) : meal.sortedRows
        let saved = weightEditingOrder.isEmpty ? ranked : ranked.sorted {
            (weightEditingOrder.firstIndex(of: $0.id) ?? Int.max) < (weightEditingOrder.firstIndex(of: $1.id) ?? Int.max)
        }
        let ids = Set(saved.map(\.id))
        var pending = Array((meal.liveProgress?.rows ?? []).filter { !ids.contains($0.id) }.prefix(1))
        if showingLiveStatus && pending.isEmpty {
            pending = [MealRow(id: meal.liveInputID, food: "")]
        }
        return saved.map { DisplayRow(row: $0, pending: $0.matchingPending == true) }
            + pending.map { DisplayRow(row: $0, pending: true) }
    }
    private func revealWeight(_ proxy: ScrollViewProxy) {
        guard let id = editingWeight, let keyboardTop = weightKeyboardTop,
              let frame = weightRowFrames[id], !weightListFrame.isEmpty else { return }
        let visibleBottom = min(weightListFrame.maxY, keyboardTop)
        guard frame.maxY > visibleBottom || frame.minY < weightListFrame.minY else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: frame.maxY > visibleBottom ? .bottom : .top)
        }
    }
    private var mealList: some View {
        ScrollViewReader { proxy in
            List {
                Group {
                if let draft = meal.draft {
                    Section {
                        if draft.day != store.today {
                            Text(draft.day.title(relativeTo: store.today))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                        }
                        if let page {
                            MealNutritionView(preview: MealNutritionPreview(page: page, draft: draft),
                                recommendation: recommendation(for: draft, page: page),
                                future: draft.day > store.today || draft.timing?.isPlanned == true)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    Section {
                        timingControl
                    }.listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                    if draft.editingEntryID == nil,
                       !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Section("Результаты поиска") {
                            ForEach(found) { product in
                                Button { UsageTelemetry.shared.action("MealEntryView.button.86"); add(product) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(product.name).foregroundStyle(.primary)
                                        if !product.displayDetail.isEmpty { Text(product.displayDetail).font(.caption).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.accessibilityIdentifier("mealSearch_\(product.id)")
                                    .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
                                    .listRowSeparator(.hidden, edges: .top)
                                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                            }
                            Button("Добавить «\(query)»") { UsageTelemetry.shared.action("MealEntryView.button.98"); add(name: query.trimmingCharacters(in: .whitespacesAndNewlines)) }
                                .accessibilityIdentifier("mealAddUnknown").listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                                .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
                                .listRowSeparator(.hidden, edges: .top)
                        }
                    }
                    Section {
                    if let diagnosticError = meal.diagnosticError {
                        Text(diagnosticError).foregroundStyle(.orange)
                        Button("Повторить сохранение архива") { UsageTelemetry.shared.action("MealEntryView.button.107");
                            Task { do { try await meal.flush() } catch { meal.diagnosticError = error.localizedDescription } }
                        }
                    }
                    ForEach(displayRows) { item in
                        Group {
                            MealVoiceFoodRow(row: item.row, pending: item.pending,
                                working: meal.liveProgress?.working == true,
                                transcript: item.row.matchingPending == true ? nil : meal.liveProgress?.phrase,
                                focusedWeight: $editingWeight,
                                editWeight: { text in
                                    meal.updateRow(item.id) { row in
                                        row.quantity = text
                                        if row.unit == nil { row.unit = .g }
                                    }
                                }, choose: {
                                    editingWeight = nil
                                    if item.row.manualNutrition != nil { quickRow = item.row }
                                    else { matchingRow = item.row }
                                })
                                .modifier(VoiceDeleteSwipe(progress: meal.voiceDeletingRows.contains(item.id) ? 1 : 0))
                                .animation(.easeInOut(duration: 0.28), value: meal.voiceDeletingRows.contains(item.id))
                                .accessibilityIdentifier("mealRow_\(item.id)")
                        }
                        .id(item.id)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            weightRowFrames[item.id] = frame
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.asymmetric(insertion: reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .top).combined(with: .opacity), removal: .opacity))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                        .listRowSeparator(.hidden, edges: .top)
                        .listRowSeparator(item.id == displayRows.last?.id && !processing ? .hidden : .visible, edges: .bottom)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 20 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width - 20 }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !item.pending {
                                Button("Удалить", systemImage: "trash", role: .destructive) { UsageTelemetry.shared.action("MealEntryView.button.145"); meal.removeRows([item.id]) }
                                    .tint(.red)
                            }
                        }
                    }
                    if processing {
                        ForEach(0..<3) { index in
                            MealLoadingRow(title: index == 0 ? processingTitle : nil, index: index)
                                .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
                                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                                .listRowSeparator(index == 2 && !showingLiveStatus ? .hidden : .visible, edges: .bottom)
                        }
                    }
                    if !processing, !showingLiveStatus, draft.rows.isEmpty,
                       query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView("Нет продуктов", systemImage: "fork.knife")
                            .frame(minHeight: 340)
                            .padding(.top, 24)
                            .accessibilityIdentifier("mealEmptyState")
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    } header: {
                        if !draft.rows.isEmpty || showingLiveStatus {
                            Text("Добавлено").font(.title2.weight(.semibold))
                                .foregroundStyle(.primary).textCase(nil)
                        }
                    }
                    if !voiceActive, let pending = draft.livePendingText, !pending.isEmpty {
                        Section("Нужно уточнить") {
                            Text(pending).font(.subheadline).foregroundStyle(.secondary)
                            TextField("Название еды", text: $unresolvedFood)
                                .accessibilityIdentifier("mealPendingFood")
                            Button("Добавить без карточки") {
                                UsageTelemetry.shared.action("MealPending.add")
                                meal.resolvePendingSpeech(asFood: unresolvedFood.isEmpty ? pending : unresolvedFood)
                                unresolvedFood = ""
                            }.disabled(locked).accessibilityIdentifier("mealPendingAdd")
                            Button("Пропустить этот фрагмент", role: .destructive) {
                                UsageTelemetry.shared.action("MealPending.skip")
                                meal.resolvePendingSpeech(asFood: nil); unresolvedFood = ""
                            }.disabled(locked).accessibilityIdentifier("mealPendingSkip")
                        }
                    }
                    if !locked, !voiceActive, meal.hasPendingDictation, draft.audioFile != nil || draft.pendingResponse != nil {
                        Button(draft.pendingResponse != nil ? "Применить полученный ответ" : "Повторить обработку диктовки") { UsageTelemetry.shared.action("MealEntryView.button.174");
                            if draft.liveMode == true || draft.transcript.isEmpty { voice.transcribeMeal(meal) }
                            else { meal.parse(reuseSavedResponse: true) }
                        }
                    }
                    if draft.pendingResponse != nil {
                        Button("Ответ модели · временная диагностика") { UsageTelemetry.shared.action("MealEntryView.button.180"); showingModelResponse = true }
                            .accessibilityIdentifier("mealModelResponse")
                    }
                    if draft.editingEntryID != nil {
                        Button("Удалить запись", role: .destructive) { UsageTelemetry.shared.action("MealEntryView.button.184"); Task { await meal.removeEntry() } }
                            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground)).listRowSeparator(.hidden)
                    }
                }
                }.disabled(meal.saving)
            }.usageScroll("MealEntryView.scroll.66")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { weightListFrame = $0 }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { notification in
                weightKeyboardTop = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.minY
                revealWeight(proxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                weightKeyboardTop = nil
            }
            .onChange(of: editingWeight) { _, _ in
                Task { @MainActor in
                    await Task.yield()
                    revealWeight(proxy)
                }
            }
        }
    }
    private var entryContent: some View {
            ZStack {
                mealList
                    .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.24), value: showingLiveStatus)
                    .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.38, bounce: 0.16), value: displayRows.map(\.id))
                    .modifier(MealContentReveal(
                        progress: searching ? 0 : 1,
                        travel: reduceMotion ? 0 : (searching ? 16 : 3)
                    ))
                    .animation(.easeOut(duration: reduceMotion ? 0.15 : (searching ? 0.25 : 0.14)), value: searching)
                    .allowsHitTesting(!searching)
                    .accessibilityHidden(searching)
                List {
                    MealNativeSearch(query: query,
                                     suggested: meal.draft?.rows.compactMap(\.product) ?? [], products: found, error: searchError,
                                     select: { add($0) }, quickEntry: { quickRow = MealRow(food: query) }, addUnknown: { add(name: $0) })
                }.usageScroll("MealEntryView.scroll.218")
                .disabled(locked)
                .padding(.top, -navigationBarHeight)
                .opacity(searching ? 1 : 0)
                .animation(searching ? .easeOut(duration: reduceMotion ? 0.15 : 0.25) : nil, value: searching)
                .allowsHitTesting(searching)
                .accessibilityHidden(!searching)
                .zIndex(1)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                bottomControlWidth = max(280, width - 32)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(meal.draft?.meal.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .contentMargins(.top, 8, for: .scrollContent)
            .background(MealSearchNavigationPolicy(navigationBarHeight: $navigationBarHeight, toolbarFade: toolbarFade))
            .toolbar { mealToolbar }
            .animation(nil, value: voiceActive)
            .searchable(text: $query, isPresented: $searching, prompt: "Найти продукт")
            .searchToolbarBehavior(searching ? .automatic : .minimize)
            .controlSize(.regular)
            .buttonBorderShape(.circle)
            .tint(Color(uiColor: .label))
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(searching, for: .top)
            .toolbarBackgroundVisibility(searching ? .hidden : .automatic, for: .navigationBar)
            .scrollEdgeEffectHidden(true, for: .bottom)
            .scrollDismissesKeyboard(.immediately)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    editingWeight = nil
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
            .scrollBounceBehavior(.always)
            .navigationBarBackButtonHidden(true)
            .onChange(of: editingWeight) { _, value in
                UsageTelemetry.shared.event("weightFocusChanged", ["rowID": value?.uuidString ?? "none"])
                if value != nil, weightEditingOrder.isEmpty {
                    weightEditingOrder = displayRows.map(\.id)
                }
                if value == nil {
                    // Keep the visible order after editing so closing the keyboard
                    // cannot move the row when its attention status changes.
                    Task { do { try await meal.flush() } catch { meal.error = error.localizedDescription } }
                }
            }


    }
    private var timingControl: some View {
        DisclosureGroup {
            Picker("Когда едите", selection: Binding(get: { meal.draft?.timing?.mode ?? .now }, set: { mode in
                UsageTelemetry.shared.action("MealTiming.mode")
                var timing = meal.draft?.timing ?? MealTiming()
                timing.mode = mode; timing.updatedAt = Date()
                timing.consumedAt = nil
                timing.selectedAt = mode == .now ? nil : (timing.selectedAt ?? meal.draft?.day.date ?? Date())
                meal.draft?.timing = timing; meal.changed()
            })) {
                Text("Сейчас").tag(MealTiming.Mode.now)
                Text("Ел раньше").tag(MealTiming.Mode.earlier)
                Text("Планирую").tag(MealTiming.Mode.planned)
            }.pickerStyle(.segmented)
            if meal.draft?.timing?.mode != .now, meal.draft?.timing != nil {
                DatePicker("Время еды", selection: Binding(get: { meal.draft?.timing?.selectedAt ?? meal.draft?.day.date ?? Date() }, set: { date in
                    UsageTelemetry.shared.action("MealTiming.time")
                    meal.draft?.timing?.selectedAt = date; meal.draft?.timing?.updatedAt = Date(); meal.draft?.day = Day(date); meal.changed()
                }), displayedComponents: [.date, .hourAndMinute])
            }
            Text(meal.draft?.timing?.isPlanned == true ? "План не считается съеденным. Подтвердите его позже в дневнике." : "Время можно уточнить. Закрытие экрана оставляет черновик.")
                .font(.caption).foregroundStyle(.secondary)
        } label: {
            Label(timingTitle, systemImage: meal.draft?.timing?.isPlanned == true ? "calendar" : "clock")
                .font(.subheadline)
        }.tint(.primary)
    }
    private var timingTitle: String {
        guard let timing = meal.draft?.timing else { return "Время еды не указано" }
        if timing.isPlanned { return "План · " + (timing.selectedAt?.formatted(date: .abbreviated, time: .shortened) ?? "выберите время") }
        if let time = timing.mode == .earlier ? timing.selectedAt : timing.consumedAt {
            return "Еда · " + time.formatted(date: .omitted, time: .shortened)
        }
        return "Сейчас · время при сохранении"
    }
    @ToolbarContentBuilder private var mealToolbar: some ToolbarContent {

                ToolbarItem(placement: .topBarLeading) {
                    Button { UsageTelemetry.shared.action("MealEntryView.button.276");
                        setSearchPresented(false); voice.background(); Task { await meal.close() }
                    } label: {
                        Image(systemName: "chevron.backward").font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .disabled(meal.saving).accessibilityLabel("Назад")
                    .accessibilityIdentifier("closeMeal")
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .modifier(MealSearchFadingControl(hidden: searching, reduceMotion: reduceMotion))
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .principal) {
                    Menu {
                        Section {
                            Button("Добавить сочетание", systemImage: "square.stack.3d.up") {
                                UsageTelemetry.shared.action("MealCombination.pick"); showingCombinations = true
                            }.disabled(locked || meal.draft?.editingEntryID != nil)
                            Button("Сохранить как сочетание", systemImage: "square.and.arrow.down") {
                                UsageTelemetry.shared.action("MealCombination.save")
                                do {
                                    combinationToSave = try FoodCombination.from(rows: meal.draft?.rows ?? [],
                                        stocks: PreparedRepository(container: store.container).stocks())
                                } catch { meal.error = error.localizedDescription }
                            }.disabled(locked || meal.draft?.rows.isEmpty != false)
                        }
                        Picker("Приём пищи", selection: Binding(get: { meal.draft?.meal ?? .breakfast }, set: { value in
                            UsageTelemetry.shared.action("MealTiming.meal")
                            meal.draft?.meal = value; meal.changed()
                        })) {
                            ForEach(Meal.allCases) { value in Text(value.title).tag(value) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(meal.draft?.meal.title ?? "Еда").font(.title3.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        }.foregroundStyle(.primary)
                    }.accessibilityLabel("Приём пищи: " + (meal.draft?.meal.title ?? "Еда"))
                        .accessibilityHint("Изменить приём пищи")
                        .modifier(MealSearchFadingControl(hidden: searching, reduceMotion: reduceMotion))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { UsageTelemetry.shared.action("MealEntryView.button.296"); setSearchPresented(false); Task { await meal.commit() } } label: {
                        Image(systemName: "checkmark").font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                        .accessibilityLabel(meal.draft?.timing?.isPlanned == true ? "Сохранить план" : "Сохранить еду")
                        .disabled(!canSave).accessibilityIdentifier("saveMeal")
                        .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                        .modifier(MealSearchFadingControl(hidden: searching, reduceMotion: reduceMotion))
                }
                .sharedBackgroundVisibility(.hidden)

            if meal.draft?.editingEntryID == nil {
                if !searching {
                    ToolbarItem(id: "mealScanner", placement: .bottomBar) {
                        Button { UsageTelemetry.shared.action("MealEntryView.button.311"); scanner = true } label: {
                            Image(systemName: "barcode.viewfinder").font(.title3)
                        }
                        .disabled(locked)
                        .accessibilityLabel("Сканировать штрихкод")
                    }
                    .sharedBackgroundVisibility(.automatic)
                    ToolbarItem(placement: .bottomBar) { Spacer() }
                    ToolbarItem(id: "mealVoice", placement: .bottomBar) {
                        MealInlineDictationControl(voice: voice, active: voiceActive,
                            reduceMotion: reduceMotion,
                            blocked: voice.processing || voice.returningMealControls || processing || meal.saving,
                            start: { startDictation() }, finish: { voice.transcribeMeal(meal) },
                            recorderFrame: $recorderFrame)
                    }
                    .sharedBackgroundVisibility(.automatic)
                    ToolbarItem(placement: .bottomBar) { Spacer() }
                }
                DefaultToolbarItem(kind: .search, placement: .bottomBar)

            }
    }
    var body: some View {
        UsageScreen("MealEntryView") {
        @Bindable var library = library
        entryContent
            .task(id: meal.draft?.day) {
                guard let day = meal.draft?.day else { return }
                page = nil
                do {
                    let loaded = try await meal.repository.page(for: day)
                    try Task.checkCancellation()
                    guard meal.draft?.day == day else { return }
                    page = loaded
                } catch is CancellationError {} catch { meal.error = error.localizedDescription }
            }
            .task(id: (meal.draft?.id.uuidString ?? "") + query) {
                let original = query, owner = meal.draft?.id
                do {
                    try await Task.sleep(for: .milliseconds(180))
                    let products = try await store.rankedSearch(original)
                    try Task.checkCancellation()
                    guard query == original, meal.draft?.id == owner else { return }
                    found = products; searchError = nil
                } catch is CancellationError {} catch {
                    guard query == original, meal.draft?.id == owner else { return }
                    found = []; searchError = error.localizedDescription
                }
            }
            .sheet(item: $combinationToSave) { CombinationEditor(initial: $0) }
            .sheet(isPresented: $showingCombinations) {
                NavigationStack {
                    List { CombinationList(onUse: { showingCombinations = false }) }
                        .navigationTitle("Сочетания")
                        .toolbar { ToolbarItem(placement: .topBarLeading) {
                            Button("Закрыть") { UsageTelemetry.shared.action("MealCombination.close"); showingCombinations = false }
                        } }
                }
            }
            .sheet(item: $quickRow) { row in
                if let owner = meal.draft?.id {
                    MealQuickEntry(row: row) { value in
                        try await meal.saveQuickEntry(value, owner: owner)
                        query = ""; found = []; searching = false
                    }
                    .presentationDetents([.large])
                }
            }
            .sheet(item: $matchingRow, onDismiss: {
                Task {
                    do { try await meal.flush() }
                    catch { meal.error = "Не удалось сохранить изменения. " + error.localizedDescription }
                }
            }) { selected in
                NavigationStack {
                    MealMatchPicker(rowID: selected.id, library: library)
                        .environment(meal).environment(store)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .usagePresentation("modelResponse", visible: showingModelResponse)
            .sheet(isPresented: $showingModelResponse) {
                NavigationStack {
                    List {
                        Section("Отправленный текст") {
                            Text(meal.draft?.transcript ?? "").textSelection(.enabled)
                        }
                        Section("Полный ответ Luna low") {
                            Text(meal.draft?.pendingResponse ?? "Ответ ещё не получен")
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        }
                        Section("Локальный подбор") {
                            Text("Полный архив: аудио, распознавание, ответ модели, подбор и правки. Хранится на iPhone без автоматического удаления.").font(.footnote)
                            if let error = meal.diagnosticError { Text("Не удалось записать диагностику: " + error).foregroundStyle(.orange) }
                            ForEach(meal.draft?.rows ?? []) { row in
                                VStack(alignment: .leading) {
                                    Text(row.food).font(.headline)
                                    Text(row.matchAttention ?? "Без неоднозначности подбора").font(.caption)
                                    ForEach(row.matchOptions ?? []) { option in
                                        Text(String(format: "%.1f", option.score) + " · " + option.product.name + " · " + option.reason).font(.caption)
                                    }
                                }
                            }
                        }
                        if let seconds = meal.draft?.lastRequestSeconds {
                            Section("Запрос") {
                                LabeledContent("Время", value: String(format: "%.2f с", seconds))
                                LabeledContent("Входные токены", value: meal.draft?.inputTokens.map(String.init) ?? "—")
                                LabeledContent("Выходные токены", value: meal.draft?.outputTokens.map(String.init) ?? "—")
                            }
                        }
                    }.usageScroll("MealEntryView.scroll.383")
                    .navigationTitle("Ответ модели").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { UsageTelemetry.shared.action("MealEntryView.button.412"); showingModelResponse = false }
                    } }
                }
            }
            .sheet(isPresented: $scanner) {
                ScannerSheet(receive: { code in query = code; scanner = false })
            }
            .sheet(isPresented: Binding(get: { library.showingEditor && matchingRow == nil }, set: {
                if matchingRow == nil { library.showingEditor = $0 }
            }), onDismiss: { Task { await meal.resumeProductLink(library) } }) {
                ProductEditor().environment(library).environment(store)
            }
            .sheet(isPresented: $voice.needsModels) {
                VStack(spacing: 24) {
                    Text("Распознавание на iPhone").font(.title2.bold())
                    Text("Parakeet распознаёт аудио на iPhone. Только текст диктовки отправляется в Polza для разбора еды.")
                    Button("Скачать модель") { UsageTelemetry.shared.action("MealEntryView.button.428"); voice.needsModels = false; voice.prepareMeal(meal) }
                        .buttonStyle(.glass(.regular.interactive()))
                }.padding(28).presentationDetents([.medium])
            }
            .alert("Не удалось выполнить действие", isPresented: Binding(get: { matchingRow == nil && (meal.error != nil || voice.error != nil) }, set: {
                if !$0 && matchingRow == nil { meal.error = nil; voice.error = nil }
            })) {
                if voice.error != nil, meal.draft?.audioFile != nil {
                    Button("Повторить распознавание") { UsageTelemetry.shared.action("MealEntryView.button.436"); voice.error = nil; voice.transcribeMeal(meal) }
                }
                if !locked, !voiceActive, meal.hasPendingDictation, meal.draft?.transcript.isEmpty == false {
                    Button(meal.draft?.liveMode == true ? "Повторить распознавание" : "Повторить запрос") { UsageTelemetry.shared.action("MealEntryView.button.439");
                        meal.error = nil; voice.error = nil
                        if meal.draft?.liveMode == true { voice.transcribeMeal(meal) } else { meal.parse() }
                    }
                }
                Button("Понятно", role: .cancel) { UsageTelemetry.shared.action("MealEntryView.button.444"); meal.error = nil; voice.error = nil }
            } message: { Text(meal.error ?? voice.error ?? "") }
            .onChange(of: voice.phase) { _, new in
                if new == .recording || new == .paused {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .onChange(of: voice.mealRecordingFinished) { _, finished in
                if finished && scenePhase == .active && meal.showing {
                    voice.mealRecordingFinished = false
                    voice.transcribeMeal(meal)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    voice.enterMealBackground()
                    if !voice.capturing { meal.cancel() }
                } else if phase == .active, voice.mealRecordingFinished, meal.showing {
                    voice.mealRecordingFinished = false
                    voice.transcribeMeal(meal)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                // The system also posts an "ended" notification. That means audio is
                // available again, not that our newly started recording must stop.
                if type == .began { voice.stop(reason: "audio-interruption-began") }
                else if voice.capturing {
                    meal.log("audioInterruptionIgnored", fields: ["type": rawType.map(String.init) ?? "missing"])
                }
            }
            .onDisappear {
                toolbarFade.cancel()
                if scenePhase == .active { voice.background() }
                else { voice.enterMealBackground() }
            }
            .task { voice.prepareMealSpeech(); await meal.resumeProductLink(library) }
            }
}
    private func setSearchPresented(_ presented: Bool) {
        searching = presented
    }
    private func startDictation() {
        guard !locked, let draftID = meal.draft?.id else { return }
        MealAnimationProbe.shared.begin()
        setSearchPresented(false)
        startingVoice = true
        MealAnimationProbe.shared.mark("presented set")
        Task {
            defer { startingVoice = false }
            await Task.yield()
            guard meal.showing, meal.draft?.id == draftID else { return }
            await voice.startMeal(meal)
        }
    }
    private func add(_ product: Product? = nil, name: String = "") {
        meal.addManual(product, name: name)
        query = ""; found = []; setSearchPresented(false)
    }
}

private struct MealInlineFoodRow: View {
    @State private var weightSelection: TextSelection?
    let row: MealRow
    let focusedWeight: FocusState<UUID?>.Binding
    let editWeight: (String) -> Void
    let choose: () -> Void
    var animateWriting = false
    private func number(_ value: Decimal?, places: Int = 1) -> String { value.map { Numbers.display($0, places: places) } ?? "—" }
    private var brandSuffix: String {
        let brand = row.product?.brand.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return brand.isEmpty ? "" : " · " + brand
    }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
                Button(action: usageAction("MealEntryView.button.510", choose)) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            MealWritingLabel(name: row.displayName.isEmpty ? "Название еды" : row.displayName,
                                             brand: brandSuffix, animated: animateWriting)
                                .lineLimit(3)
                            if row.requiresAttention {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                                    .accessibilityLabel("Требует внимания")
                            }
                        }
                        if row.product?.preparedBatchID != nil {
                            Text("Из приготовленного · списать " + Numbers.display(row.batchPortions ?? 1) + " порц.").font(.caption).foregroundStyle(.secondary)
                        }
                        if row.manualNutrition != nil { Text("Быстрый ввод").font(.caption).foregroundStyle(.secondary) }
                        if let attention = row.matchAttention { Text(attention).font(.caption).foregroundStyle(.orange) }
                        MealWritingLabel(name: "\(number(row.portion.calories, places: 0)) ккал · Б \(number(row.portion.protein)) · Ж \(number(row.portion.fat)) · У \(number(row.portion.carbs))",
                                         brand: "", animated: animateWriting, font: .caption, color: .secondary, delay: 240)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if row.manualNutrition == nil {
                    ZStack(alignment: .trailing) {
                        // Keep the focus target mounted before the quantity button requests it.
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                TextField("—", text: Binding(get: { row.quantityEditingText }, set: editWeight), selection: $weightSelection)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .focused(focusedWeight, equals: row.id)
                                    .accessibilityLabel("Количество: " + row.displayName)
                                    .accessibilityIdentifier("mealWeight_\(row.id)")
                                Text(row.unit?.title ?? "г").foregroundStyle(.secondary)
                            }
                            .frame(width: 80, height: 44)
                            .opacity(focusedWeight.wrappedValue == row.id ? 1 : 0)
                            .allowsHitTesting(focusedWeight.wrappedValue == row.id)
                            .accessibilityHidden(focusedWeight.wrappedValue != row.id)
                        if focusedWeight.wrappedValue != row.id {
                            Button { UsageTelemetry.shared.action("MealEntryView.button.551"); focusedWeight.wrappedValue = row.id } label: {
                                MealWritingLabel(name: (row.quantity.isEmpty ? "—" : row.amount.map { Numbers.display($0) } ?? row.quantity) + " " + (row.unit?.title ?? "г"),
                                                 brand: "", animated: animateWriting, delay: 480)
                                    .fixedSize()
                                    .frame(width: 80, height: 44, alignment: .trailing)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Изменить количество: " + row.displayName)
                            .accessibilityIdentifier("mealWeight_\(row.id)")
                        }
                    }
                    .task(id: focusedWeight.wrappedValue) {
                        guard focusedWeight.wrappedValue == row.id else { return }
                        await Task.yield()
                        guard !Task.isCancelled, focusedWeight.wrappedValue == row.id else { return }
                        weightSelection = TextSelection(range: row.quantityEditingText.startIndex..<row.quantityEditingText.endIndex)
                    }
                    .font(.body).monospacedDigit()
                    .contentShape(Rectangle())
                    .layoutPriority(1)
                }
        }
        .frame(minHeight: 44)
    }
}

/// Visual full-swipe for voice deletion, matching the supplied iOS 26 screenshots.
nonisolated private struct VoiceDeleteSwipe: AnimatableModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    @MainActor @State private var width: CGFloat = 0
    @MainActor private var reveal: CGFloat { width * min(1, max(0, progress)) }
    @MainActor func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .offset(x: reduceMotion ? 0 : -reveal)
            .opacity(reduceMotion ? 1 - progress : 1)
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay(alignment: .trailing) {
                if !reduceMotion {
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(Color(uiColor: .systemRed))
                            .overlay {
                                Image(systemName: "trash")
                                    .font(.system(size: 20, weight: .regular))
                                    .foregroundStyle(.white)
                            }
                            .frame(height: 48)
                        Text("Удалить")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    // All geometry is derived from the same interpolated progress.
                    // Never impose a minimum width: it would invade the moving gap.
                    .frame(width: max(0, reveal - 24))
                    .padding(.horizontal, 12)
                    .frame(width: reveal, alignment: .trailing)
                    .clipped()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct MealMatchPicker: View {
    @Environment(MealSession.self) private var meal
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let rowID: UUID
    let library: ProductLibrary
    @State private var query = ""
    @State private var searchError: String?
    @State private var found: [Product] = []
    @State private var showingSearch = false
    @FocusState private var focused: Field?
    private enum Field: Hashable { case amount, search }
    private var row: MealRow? { meal.draft?.rows.first { $0.id == rowID } }
    private var options: [ProductCandidate] { meal.displayedCandidates(for: rowID) }
    var body: some View {
        UsageScreen("MealMatchPicker") {
        List {
            if let row {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(row.food).font(.headline).foregroundStyle(.primary)
                        HStack {
                            Text("Вес").foregroundStyle(.secondary)
                            Spacer()
                            TextField("Количество", text: Binding(get: { self.row?.quantityEditingText ?? "" }, set: { value in
                                meal.updateRow(rowID) {
                                    $0.quantity = value
                                    if $0.unit == nil { $0.unit = .g }
                                }
                            }))
                            .keyboardType(.decimalPad).focused($focused, equals: .amount)
                            .multilineTextAlignment(.trailing).font(.title3.weight(.medium))
                            .frame(width: 120).accessibilityLabel("Вес продукта")
                            .accessibilityIdentifier("quickMatchAmount")
                            Text(row.unit?.title ?? "г").foregroundStyle(.secondary)
                        }
                        if row.product?.preparedBatchID != nil {
                            Stepper(value: Binding(get: { NSDecimalNumber(decimal: row.batchPortions ?? 1).doubleValue },
                                set: { value in meal.updateRow(rowID) { $0.batchPortions = Decimal(value) } }),
                                in: 0.5...20, step: 0.5) {
                                Text("Списать порций: " + Numbers.display(row.batchPortions ?? 1))
                            }
                        }
                        if !row.quantity.isEmpty && row.amount == nil {
                            Text("Введите количество больше нуля").font(.caption).foregroundStyle(.orange)
                        }
                    }.padding(.vertical, 4)
                }
                if showingSearch {
                    Section {
                        TextField("Найти в полном каталоге", text: $query)
                            .focused($focused, equals: .search)
                            .accessibilityIdentifier("quickMatchSearch")
                    }
                }
                if query.isEmpty {
                    Section("Ближайшие варианты") {
                        ForEach(options) { option in
                            Button { UsageTelemetry.shared.action("MealEntryView.button.684"); meal.choose(option.product, for: rowID); dismiss() } label: {
                                candidateLabel(option.product)
                            }.accessibilityIdentifier("quickMatch_" + option.id)
                        }
                        if options.isEmpty { Text("Подходящих вариантов пока нет").foregroundStyle(.secondary) }
                    }
                } else {
                    Section("Весь каталог") {
                        ForEach(found) { product in
                            Button { UsageTelemetry.shared.action("MealEntryView.button.693"); meal.choose(product, for: rowID); dismiss() } label: { candidateLabel(product) }
                        }
                        if found.isEmpty { Text("Нет подходящих продуктов").foregroundStyle(.secondary) }
                    }
                }
                Section {
                    Button { UsageTelemetry.shared.action("MealEntryView.button.699");
                        var unlinked = row; unlinked.product = nil
                        Task { await meal.createProduct(for: unlinked, library: library) }
                    } label: { Label("Создать «" + row.food + "»", systemImage: "plus") }
                    NavigationLink("Дополнительные сведения") { MealRowEditor(rowID: rowID, library: library) }
                }
            }
        }.usageScroll("MealEntryView.scroll.646")
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Продукт").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Поиск", systemImage: "magnifyingglass") { UsageTelemetry.shared.action("MealEntryView.button.713"); showingSearch = true; focused = .search }
            }
            ToolbarItem(placement: .confirmationAction) { Button("Готово") { UsageTelemetry.shared.action("MealEntryView.button.715"); dismiss() } }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Готово") { UsageTelemetry.shared.action("MealEntryView.button.716"); focused = nil } }
        }
        .tint(.primary)
        .sheet(isPresented: Binding(get: { library.showingEditor }, set: { library.showingEditor = $0 }),
               onDismiss: { Task { await meal.resumeProductLink(library) } }) {
            ProductEditor().environment(library).environment(store)
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { meal.error != nil && !library.showingEditor }, set: {
            if !$0 && !library.showingEditor { meal.error = nil }
        })) {
            Button("Понятно", role: .cancel) { UsageTelemetry.shared.action("MealEntryView.button.726"); meal.error = nil }
        } message: { Text(meal.error ?? "") }
        .task { await meal.refreshCandidates(for: rowID) }
        .task(id: query) {
            guard !query.isEmpty else { found = []; return }
            do {
                try await Task.sleep(for: .milliseconds(180))
                let result = try await meal.manualSearch(query, rowID: rowID)
                try Task.checkCancellation(); found = result
            } catch is CancellationError {} catch { meal.error = error.localizedDescription }
        }
            }
}
    private func candidateLabel(_ product: Product) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name).font(.body).foregroundStyle(.primary)
                if !product.displayDetail.isEmpty { Text(product.displayDetail).font(.caption).foregroundStyle(.secondary) }
                Text(nutritionLabel(product)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if row?.product?.id == product.id { Image(systemName: "checkmark").foregroundStyle(.primary) }
        }.padding(.vertical, 2)
    }
    private func nutritionLabel(_ product: Product) -> String {
        func value(_ number: Decimal?, places: Int = 1) -> String { number.map { Numbers.display($0, places: places) } ?? "—" }
        let basis = product.basis == .g ? "г" : product.basis == .ml ? "мл" : "?"
        return "\(value(product.calories, places: 0)) ккал · Б \(value(product.protein)) · Ж \(value(product.fat)) · У \(value(product.carbs)) / 100 \(basis)"
    }
}

private struct MealRowEditor: View {
    @Environment(MealSession.self) private var meal
    @Environment(DiaryStore.self) private var store
    let rowID: UUID
    let library: ProductLibrary
    @State private var query = ""
    @State private var searchError: String?
    @State private var found: [Product] = []
    private var row: MealRow? { meal.draft?.rows.first { $0.id == rowID } }
    var body: some View {
        UsageScreen("MealRowEditor") {
        Form {
            if let row {
                Section {
                    TextField("Название еды", text: Binding(get: { self.row?.food ?? "" }, set: { value in
                        guard self.row?.food != value else { return }
                        meal.updateRow(rowID) { $0.food = value; $0.product = nil; $0.suggested = false }
                    })).font(.title3).accessibilityIdentifier("mealFoodName")
                    HStack {
                        TextField("Количество", text: Binding(get: { self.row?.quantityEditingText ?? "" }, set: { value in
                            meal.updateRow(rowID) { $0.quantity = value }
                        })).keyboardType(.decimalPad).font(.title2).accessibilityIdentifier("mealAmount")
                        Picker("Единица", selection: Binding(get: { self.row?.unit }, set: { value in meal.updateRow(rowID) { $0.unit = value } })) {
                            Text("Не указана").tag(FoodUnit?.none)
                            ForEach(FoodUnit.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                        }.accessibilityIdentifier("mealUnit")
                    }
                }
                Section {
                    if let product = row.product {
                        Text(product.name).font(.headline)
                        if !product.displayDetail.isEmpty { Text(product.displayDetail).foregroundStyle(.secondary) }
                        Button("Убрать привязку") { UsageTelemetry.shared.action("MealEntryView.button.787"); meal.choose(nil, for: rowID) }
                    } else { Text("Без карточки продукта").foregroundStyle(.secondary) }
                    if row.portion.complete {
                        Text("\(Numbers.display(row.portion.calories!, places: 0)) ккал · Б \(Numbers.display(row.portion.protein!, places: 1)) · Ж \(Numbers.display(row.portion.fat!, places: 1)) · У \(Numbers.display(row.portion.carbs!, places: 1)) г")
                    } else {
                        Text("Можно сохранить сейчас. Калории и БЖУ появятся после уточнения продукта и количества.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let product = row.product, product.basis == .unknown {
                        Picker("КБЖУ указаны на 100", selection: Binding(get: { self.row?.product?.basis ?? .unknown }, set: { basis in
                            meal.updateRow(rowID) { $0.product?.basis = basis; $0.confirmedBasis = true }
                        })) { Text("Не выбрано").tag(Basis.unknown); Text("г").tag(Basis.g); Text("мл").tag(Basis.ml) }
                            .accessibilityIdentifier("mealBasis")
                    }
                    Button(row.product == nil ? "Создать карточку" : "Дополнить карточку") { UsageTelemetry.shared.action("MealEntryView.button.800");
                        Task { await meal.createProduct(for: row, library: library) }
                    }.accessibilityIdentifier("mealCreateProduct")
                } header: { Text("Продукт и КБЖУ") }
                if !meal.displayedCandidates(for: rowID).isEmpty {
                    Section("Возможные продукты") {
                        ForEach(meal.displayedCandidates(for: rowID)) { option in
                            Button { UsageTelemetry.shared.action("MealEntryView.button.807"); meal.choose(option.product, for: rowID) } label: {
                                VStack(alignment: .leading) { Text(option.product.name); Text(option.reason).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section("Выбрать из каталога") {
                    TextField("Поиск или штрихкод", text: $query).accessibilityIdentifier("mealProductSearch")
                    ForEach(found) { product in
                        Button { UsageTelemetry.shared.action("MealEntryView.button.816"); meal.choose(product, for: rowID); query = ""; found = [] } label: {
                            VStack(alignment: .leading) { Text(product.name); Text(product.brand).font(.caption).foregroundStyle(.secondary) }
                        }.accessibilityIdentifier("mealCandidate_\(product.id)")
                    }
                }
            }
        }.usageScroll("MealEntryView.scroll.772").navigationTitle("Еда и количество").navigationBarTitleDisplayMode(.inline)
            .task(id: query) {
                guard !query.isEmpty else { found = []; return }
                do {
                    try await Task.sleep(for: .milliseconds(180))
                    let products = try await meal.manualSearch(query, rowID: rowID)
                    try Task.checkCancellation(); found = products
                } catch is CancellationError {} catch { meal.error = error.localizedDescription }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("Готово") { UsageTelemetry.shared.action("MealEntryView.button.833"); UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            }
}
}

struct MealAPISettings: View {
    @State private var key = ""
    @State private var configured = false
    @State private var message: String?
    var body: some View {
        UsageScreen("MealAPISettings") {
        Form {
            Section {
                if configured { Label("Ключ сохранён на этом iPhone", systemImage: "checkmark.circle") }
                SecureField(configured ? "Новый ключ Polza" : "API-ключ Polza", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Сохранить ключ") { UsageTelemetry.shared.action("MealEntryView.button.849");
                    do { try MealAPIKey.save(key); key = ""; configured = true; message = "Ключ сохранён." }
                    catch { message = error.localizedDescription }
                }.disabled(key.isEmpty)
                if configured {
                    Button("Удалить ключ", role: .destructive) { UsageTelemetry.shared.action("MealEntryView.button.854");
                        do { try MealAPIKey.remove(); configured = false; message = "Ключ удалён." }
                        catch { message = error.localizedDescription }
                    }
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            } header: { Text("Polza · Luna") } footer: {
                Text("Для личной пробы ключ хранится в Связке ключей этого iPhone. В Polza отправляется только текст текущей диктовки. Один разбор — один запрос; повтор запускается вручную.")
            }
            Section {
                Link("Открыть кабинет Polza", destination: URL(string: "https://polza.ai/dashboard")!)
                Text("Расход зависит от длины текста и ответа. Баланс и лимит ключа можно проверить в кабинете.").foregroundStyle(.secondary)
            }
        }.usageScroll("MealEntryView.scroll.852").navigationTitle("Разбор еды").navigationBarTitleDisplayMode(.inline)
            .onAppear { do { configured = try MealAPIKey.read() != nil } catch { message = error.localizedDescription } }
            }
}
}

private struct MealLoadingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String?
    let index: Int
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
            let pulse = reduceMotion ? 0.22 : 0.16 + 0.10 * (sin(context.date.timeIntervalSinceReferenceDate * 3 - Double(index) * 0.5) + 1) / 2
            VStack(alignment: .leading, spacing: 8) {
                if let title { Text(title).font(.body).foregroundStyle(.secondary) }
                else { Capsule().fill(Color.secondary.opacity(pulse)).frame(width: index == 1 ? 175 : 130, height: 17) }
                Capsule().fill(Color.secondary.opacity(pulse)).frame(width: 215, height: 11)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? "Загрузка продукта")
    }
}


/// One stable List identity owns listening, word collection and the editable result.
private struct MealVoiceFoodRow: View {
    let row: MealRow
    let pending: Bool
    let working: Bool
    let transcript: String?
    let focusedWeight: FocusState<UUID?>.Binding
    let editWeight: (String) -> Void
    let choose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if pending {
                MealSearchingFoodRow(row: row, transcript: transcript)
            } else {
                MealInlineFoodRow(row: row, focusedWeight: focusedWeight,
                                  editWeight: editWeight, choose: choose)
            }
        }
        .frame(minHeight: 44)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.22), value: pending)
    }
}

/// Presentation only: typing never delays recognition or committing a row.
private struct MealSearchingFoodRow: View {
    let row: MealRow
    let transcript: String?
    private var sourceText: String {
        let source = transcript ?? row.food
        // Display only. Keep decimal meaning without drawing punctuation.
        let decimals = source.replacingOccurrences(of: #"(?<=\d)[.,](?=\d)"#,
            with: " запятая ", options: .regularExpression)
        let plain = decimals.map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : Character(" ") }
        return String(plain).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private var targetText: String { FoodWordFilter.apply(sourceText).text }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var written = ""
    @State private var previousSource = ""

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if targetText.isEmpty && written.isEmpty {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Ожидание речи")
                } else {
                (Text(written) + Text("▏").foregroundColor(.secondary))
                    .font(.body).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    .phaseAnimator([false, true]) { content, raised in
                        content
                            .scaleEffect(reduceMotion ? 1 : (raised ? 1.003 : 1), anchor: .leading)
                            .offset(y: reduceMotion ? 0 : (raised ? -0.4 : 0.4))
                    } animation: { _ in .easeInOut(duration: 1.4) }
                    .accessibilityLabel(targetText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if transcript == nil && !row.quantity.isEmpty {
                Text((row.amount.map { Numbers.display($0) } ?? row.quantity) + " г").font(.body).monospacedDigit()
                    .contentTransition(.numericText())
                    .fixedSize()
            }
        }
        .frame(minHeight: 44)
        .task(id: sourceText) {
            let incoming = sourceText
            let appended = incoming.hasPrefix(previousSource)
            let suffix = appended ? String(incoming.dropFirst(previousSource.count)) : ""
            let staged = appended ? written + suffix : targetText
            previousSource = incoming
            guard !reduceMotion else { written = targetText; return }
            do {
                for (stage, value) in [staged, targetText].enumerated() {
                    if stage == 1 && staged != targetText { try await Task.sleep(for: .milliseconds(100)) }
                    let target = Array(value)
                    // A diff deletes only revised/filtered characters. Unchanged words
                    // after an edit stay visible instead of being erased and typed again.
                    let changes = target.difference(from: Array(written))
                    let delay = min(16, max(2, 240 / max(1, changes.count)))
                    for change in changes {
                        try await Task.sleep(for: .milliseconds(delay))
                        try Task.checkCancellation()
                        var letters = Array(written)
                        switch change {
                        case let .remove(offset, _, _): letters.remove(at: offset)
                        case let .insert(offset, element, _): letters.insert(element, at: offset)
                        }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { written = String(letters) }
                    }
                }
            } catch { /* A new hypothesis continues from the currently visible text. */ }
        }
    }
}

struct MealWritingLabel: View {
    let name: String
    let brand: String
    let animated: Bool
    var font: Font = .body
    var color: Color = .primary
    var delay: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var count = 0
    private func label(_ count: Int) -> Text {
        Text(String(name.prefix(count))).font(font).foregroundStyle(color)
        + Text(String(brand.prefix(max(0, count - name.count)))).font(.subheadline).foregroundStyle(Color.secondary)
    }
    var body: some View {
        label(name.count + brand.count).hidden()
            .overlay(alignment: .topLeading) { label(animated && !reduceMotion ? count : name.count + brand.count) }
            .accessibilityElement(children: .ignore).accessibilityLabel(name + brand)
            .task(id: name + brand) {
                let total = name.count + brand.count
                guard animated && !reduceMotion else { count = total; return }
                do {
                    count = 0
                    if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                    for step in 1...12 {
                        try Task.checkCancellation()
                        count = (total * step + 11) / 12
                        try await Task.sleep(for: .milliseconds(20))
                    }
                } catch {}
            }
    }
}


struct MealHistoryFoodRow: View {
    let row: MealRow
    private func number(_ value: Decimal?, places: Int = 1) -> String { value.map { Numbers.display($0, places: places) } ?? "—" }
    var body: some View {
        let brand = row.product?.brand.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                MealWritingLabel(name: row.displayName, brand: brand.isEmpty ? "" : " · " + brand, animated: false)
                    .lineLimit(3)
                Text("\(number(row.portion.calories, places: 0)) ккал · Б \(number(row.portion.protein)) · Ж \(number(row.portion.fat)) · У \(number(row.portion.carbs))")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if row.timing?.isPlanned == true { Text("План").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if row.manualNutrition == nil {
                Text(row.quantityLabel).font(.body).frame(minWidth: 64, alignment: .trailing).fixedSize()
            }
        }.accessibilityElement(children: .combine)
    }
}
