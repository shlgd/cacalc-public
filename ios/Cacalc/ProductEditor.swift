import SwiftUI
import AVFoundation

private enum ProductField: String, CaseIterable {
    case name, brand, calories, protein, fat, carbs
    var numeric: Bool { self != .name && self != .brand }
    var title: String {
        switch self {
        case .name: "Название"
        case .brand: "Марка"
        case .calories: "Калории"
        case .protein: "Белки"
        case .fat: "Жиры"
        case .carbs: "Углеводы"
        }
    }
    var path: WritableKeyPath<ProductCreationDraft, String> {
        switch self {
        case .name: \.name
        case .brand: \.brand
        case .calories: \.calories
        case .protein: \.protein
        case .fat: \.fat
        case .carbs: \.carbs
        }
    }
    var id: String { "product" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var color: Color {
        switch self {
        case .protein: .blue
        case .fat: .orange
        case .carbs: .purple
        default: .green
        }
    }
}

struct ProductEditor: View {
    @Environment(ProductLibrary.self) private var library
    @Environment(DiaryStore.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var voice = VoiceSession.mealVoice
    @State private var discard = false
    @State private var barcodeOpen = false
    @State private var scannerOpen = false
    @State private var barcodeNotice: String?
    @State private var scanCount = 0
    @FocusState private var focused: ProductField?
    @ScaledMetric(relativeTo: .title) private var nameSize = 30.0
    @ScaledMetric(relativeTo: .title3) private var brandSize = 20.0
    @ScaledMetric(relativeTo: .subheadline) private var labelSize = 15.0
    @ScaledMetric(relativeTo: .footnote) private var statusSize = 13.0
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize = 42.0

    private func text(_ path: WritableKeyPath<ProductCreationDraft, String>) -> Binding<String> {
        Binding(get: { library.draft?[keyPath: path] ?? "" }, set: {
            library.draft?[keyPath: path] = $0; library.changed()
        })
    }
    private var canSave: Bool { library.draft.flatMap { try? $0.product() } != nil }
    private var pendingVoice: Bool { library.draft?.pendingVoiceStage != nil }

    var body: some View {
        UsageScreen("ProductEditor") {
        NavigationStack {
            GeometryReader { geometry in
                let tileHeight = min(122, max(66, (geometry.size.height - 326) / 2))
                VStack(spacing: 0) {
                    identity
                    nutrition(height: tileHeight).padding(.top, 18)
                    if let notice = barcodeNotice ?? library.draft?.notices.first {
                        Text(notice).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            .padding(.top, 18)
                    }
                    Spacer(minLength: 0)
                    voiceDock
                }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(library.draft?.editingProductID == nil ? "Новый продукт" : "Продукт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { editorToolbar }
            .interactiveDismissDisabled()
            .onChange(of: phase) { _, value in
                if value == .background { voice.background(); library.changed() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                if (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                    voice.stop(reason: "audio-interruption-began"); library.changed()
                }
            }
            .onDisappear { voice.background() }
            .onChange(of: voice.phase) { _, _ in barcodeNotice = nil }
            .sensoryFeedback(.success, trigger: scanCount)
            .sheet(isPresented: $scannerOpen) {
                ScannerSheet(receive: { code in
                    scannerOpen = false
                    Task {
                        barcodeNotice = await library.scan(code, catalog: store.catalog)
                        if barcodeNotice != nil { scanCount += 1 }
                    }
                }, unavailableMessage: "Разрешите доступ к камере в настройках iPhone. Карточку можно продолжить заполнять голосом или вручную.",
                   returnTitle: "Вернуться к карточке")
            }
            .sheet(isPresented: $barcodeOpen) {
                ProductBarcodeEditor(value: text(\.barcode))
                    .presentationDetents([.height(210)]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: Binding(get: { voice.needsModels }, set: { voice.needsModels = $0 })) {
                voiceSetup.presentationDetents([.medium]).presentationDragIndicator(.visible)
            }
            .confirmationDialog("Удалить незавершённую карточку?", isPresented: $discard, titleVisibility: .visible) {
                Button("Удалить черновик", role: .destructive) { UsageTelemetry.shared.action("ProductEditor.button.116"); Task { await library.discard() } }
            }
            .alert("Не удалось выполнить действие", isPresented: Binding(
                get: { voice.error != nil || library.error != nil },
                set: { if !$0 { voice.error = nil; library.error = nil } })) {
                Button("Понятно", role: .cancel) { UsageTelemetry.shared.action("ProductEditor.button.121"); voice.error = nil; library.error = nil }
                if pendingVoice && !voice.locked {
                    Button("Повторить") { UsageTelemetry.shared.action("ProductEditor.button.123"); voice.error = nil; library.error = nil; voice.transcribe(library) }
                }
            } message: { Text(voice.error ?? library.error ?? "") }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
            }
}

    private var identity: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Название", text: text(\.name), prompt: Text("Название").foregroundStyle(Color(uiColor: .secondaryLabel)), axis: .vertical)
                .font(.system(size: min(nameSize, 46), weight: .semibold))
                .lineLimit(1...2).focused($focused, equals: .name)
                .submitLabel(.next).onSubmit { focused = .brand }
                .accessibilityLabel("Название").accessibilityIdentifier("productName")
            Divider()
            TextField("Марка", text: text(\.brand), prompt: Text("Марка").foregroundStyle(Color(uiColor: .secondaryLabel)))
                .font(.system(size: min(brandSize, 32))).focused($focused, equals: .brand)
                .submitLabel(.next).onSubmit { focused = .calories }
                .accessibilityLabel("Марка").accessibilityIdentifier("productBrand")
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
        .disabled(voice.locked || library.busy)
    }

    private func nutrition(height: CGFloat) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text("На 100").font(.system(size: min(labelSize, 22), weight: .medium)).foregroundStyle(.secondary)
                Picker("Основа пищевой ценности", selection: Binding(get: { library.draft?.basis ?? .g }, set: {
                    library.draft?.basis = $0; library.changed()
                })) {
                    Text("г").tag(Basis.g)
                    Text("мл").tag(Basis.ml)
                    if library.draft?.basis == .unknown { Text("?").tag(Basis.unknown) }
                }.pickerStyle(.segmented).frame(width: 148).accessibilityIdentifier("productBasis")
                Spacer(minLength: 0)
            }.padding(.horizontal, 4)
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    nutrient(.calories, height: height)
                    nutrient(.protein, height: height)
                }
                HStack(spacing: 12) {
                    nutrient(.fat, height: height)
                    nutrient(.carbs, height: height)
                }
            }
        }.disabled(voice.locked || library.busy)
    }

    private func nutrient(_ field: ProductField, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: height < 85 ? 3 : 8) {
            Text(field.title).font(.system(size: min(labelSize, 22), weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.6)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                TextField("—", text: text(field.path))
                    .font(.system(size: min(numberSize, height * 0.40), weight: .semibold))
                    .monospacedDigit().keyboardType(.decimalPad)
                    .focused($focused, equals: field)
                    .foregroundStyle(field == .calories ? calorieColor : Color.primary)
                    .accessibilityLabel(field.title).accessibilityIdentifier(field.id)
                if field != .calories { Text("г").font(.system(size: min(labelSize, 18))).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(field == .calories ? Color.green.opacity(0.09) : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24).strokeBorder(field.color.opacity(focused == field ? 0.75 : 0), lineWidth: 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .onTapGesture { UsageTelemetry.shared.event("productFieldFocused", ["field": String(describing: field)]); focused = field }
        .tint(field.color)
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { UsageTelemetry.shared.action("ProductEditor.button.201"); close() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Закрыть").accessibilityIdentifier("closeProduct")
                .disabled(library.busy)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Штрихкод", systemImage: "barcode") { UsageTelemetry.shared.action("ProductEditor.button.207"); focused = nil; barcodeOpen = true }
                if pendingVoice {
                    Button("Новая диктовка", systemImage: "mic") { UsageTelemetry.shared.action("ProductEditor.button.209"); Task { await voice.start(library) } }
                }
                Button("Удалить черновик", systemImage: "trash", role: .destructive) { UsageTelemetry.shared.action("ProductEditor.button.211"); discard = true }
            } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Дополнительно").accessibilityIdentifier("productMore")
                .disabled(voice.locked || library.busy)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button { UsageTelemetry.shared.action("ProductEditor.button.217");
                focused = nil
                Task { await library.commit() }
            } label: { Image(systemName: "checkmark") }
                .buttonStyle(.glassProminent)
                .accessibilityLabel("Сохранить продукт").accessibilityIdentifier("saveProduct")
                .disabled(!canSave || voice.locked || library.busy)
        }
        ToolbarItem(placement: .keyboard) {
            HStack(spacing: 8) {
                Button { UsageTelemetry.shared.action("ProductEditor.button.227"); moveFocus(-1) } label: { Image(systemName: "chevron.up").frame(width: 36, height: 44) }
                    .accessibilityLabel("Предыдущее поле").disabled(focused == .name)
                Button { UsageTelemetry.shared.action("ProductEditor.button.229"); moveFocus(1) } label: { Image(systemName: "chevron.down").frame(width: 36, height: 44) }
                    .accessibilityLabel("Следующее поле").accessibilityIdentifier("nextProductField")
                    .disabled(focused == .carbs)
                if let focused, focused.numeric {
                    let value = text(focused.path).wrappedValue
                    Text("\(focused.title)\n\(value.isEmpty ? "—" : value)\(focused == .calories ? "" : " г")")
                        .font(.system(size: min(statusSize, 17), weight: .medium)).monospacedDigit()
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.65)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("productKeyboardValue")
                } else { Spacer() }
                Button("Готово") { UsageTelemetry.shared.action("ProductEditor.button.240"); focused = nil }
                    .font(.system(size: min(brandSize, 22)))
                    .accessibilityIdentifier("productKeyboardDone")
            }
            .font(.system(size: 18, weight: .medium)).buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }

    private var voiceDock: some View {
        VStack(spacing: 9) {
            HStack(spacing: 22) {
                Group {
                    if voice.capturing {
                        Button { UsageTelemetry.shared.action("ProductEditor.button.254"); voice.pause() } label: { Image(systemName: voice.phase == .paused ? "play.fill" : "pause.fill").frame(width: 24, height: 24) }
                            .buttonStyle(.glass(.regular.interactive())).buttonBorderShape(.circle)
                            .accessibilityLabel(voice.phase == .paused ? "Продолжить запись" : "Пауза")
                    } else {
                        Button { UsageTelemetry.shared.action("ProductEditor.button.258"); focused = nil; scannerOpen = true } label: {
                            Image(systemName: "barcode.viewfinder")
                                .font(.system(size: 21, weight: .medium)).frame(width: 24, height: 24)
                        }
                        .buttonStyle(.glass(.regular.interactive())).buttonBorderShape(.circle)
                        .accessibilityLabel("Сканировать штрихкод")
                        .accessibilityValue(library.draft?.barcode ?? "")
                        .accessibilityIdentifier("productScanner")
                        .disabled(voice.locked || library.busy)
                    }
                }.frame(width: 46, height: 46)
                Button { UsageTelemetry.shared.action("ProductEditor.button.269");
                    if voice.processing { voice.cancel() }
                    else if voice.capturing || pendingVoice { voice.transcribe(library) }
                    else { Task { await voice.start(library) } }
                } label: {
                    Image(systemName: voice.processing ? "xmark" : voice.capturing ? "checkmark" : pendingVoice ? "arrow.clockwise" : "mic.fill")
                        .font(.system(size: 27, weight: .semibold)).frame(width: 58, height: 58)
                        .foregroundStyle(voice.capturing ? Color.red : Color.primary)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .buttonStyle(.glass(.regular.interactive())).buttonBorderShape(.circle)
                .accessibilityLabel(voice.processing ? "Остановить обработку" : voice.capturing ? "Готово, заполнить карточку" : pendingVoice ? "Продолжить обработку диктовки" : "Диктовать продукт")
                .accessibilityIdentifier("productVoice")
                .disabled(library.busy || voice.phase == .requesting)
                Color.clear.frame(width: 46, height: 46)
            }
            HStack(spacing: 7) {
                if voice.processing || voice.phase == .requesting { ProgressView().controlSize(.mini) }
                Text(voiceStatus).font(.system(size: min(statusSize, 20))).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }.accessibilityIdentifier("productVoiceStatus")
        }
        .frame(maxWidth: .infinity).padding(.bottom, 4)
    }

    private var voiceStatus: String {
        switch voice.phase {
        case .idle: pendingVoice ? "Продолжить" : "Диктовать"
        case .requesting: "Включаю микрофон"
        case .recording: "Говорите"
        case .paused: "Пауза"
        case .transcribing: "Распознаю"
        case .extracting: "Заполняю поля"
        case .downloading: "Загружаю модели"
        }
    }

    private var calorieColor: Color {
        colorScheme == .dark ? .green : Color(red: 0.10, green: 0.43, blue: 0.23)
    }

    private var voiceSetup: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.fill").font(.largeTitle).foregroundStyle(.green)
            Text("Подготовить диктовку").font(.title2.bold())
            Text("Для распознавания речи нужен Parakeet — 483 МБ. Достаточно загрузить один раз. Поля заполняются локально.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if voice.phase == .downloading {
                ProgressView(value: voice.progress)
                Text(voice.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                Button("Остановить загрузку", role: .cancel) { UsageTelemetry.shared.action("ProductEditor.button.319"); voice.cancel() }
            } else {
                Button("Загрузить модели") { UsageTelemetry.shared.action("ProductEditor.button.321"); voice.prepare(library) }.buttonStyle(.glassProminent)
            }
        }.padding(28).interactiveDismissDisabled(voice.phase == .downloading)
    }

    private func moveFocus(_ step: Int) {
        guard let focused, let index = ProductField.allCases.firstIndex(of: focused),
              ProductField.allCases.indices.contains(index + step) else { return }
        self.focused = ProductField.allCases[index + step]
    }
    private func close() {
        focused = nil; voice.background()
        Task {
            do { try await library.flush(); library.showingEditor = false }
            catch { library.error = "Черновик пока не сохранён. " + error.localizedDescription }
        }
    }
}

private struct ProductBarcodeEditor: View {
    @Binding var value: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    var body: some View {
        UsageScreen("ProductBarcodeEditor") {
        NavigationStack {
            TextField("Штрихкод", text: $value).font(.title2).keyboardType(.numberPad)
                .focused($focused).padding(24).frame(maxHeight: .infinity, alignment: .top)
                .accessibilityIdentifier("productBarcode")
                .navigationTitle("Штрихкод").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { UsageTelemetry.shared.action("ProductEditor.button.350"); dismiss() } } }
                .onAppear { focused = true }
        }
            }
}
}
