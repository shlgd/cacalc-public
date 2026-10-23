import SwiftUI
import Charts

struct BodyMeasurementsView: View {
    @Environment(DiaryStore.self) private var diary
    @State private var kind: MeasurementKind = .weight
    @State private var records: [BodyMeasurement] = []
    @State private var editing: BodyMeasurement?
    @State private var adding = false
    @State private var error: String?
    private var selected: [BodyMeasurement] { records.filter { $0.kind == kind } }
    var body: some View {
        List {
            Picker("Измерение", selection: $kind) {
                ForEach(MeasurementKind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).listRowBackground(Color.clear)
            if let latest = selected.first {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Numbers.display(latest.value, places: 2) + " " + kind.unit).font(.largeTitle.weight(.semibold)).monospacedDigit()
                        Text(latest.measuredAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                    if selected.count > 1 {
                        Chart(selected.sorted { $0.measuredAt < $1.measuredAt }) { record in
                            LineMark(x: .value("Дата", record.measuredAt), y: .value(kind.unit, NSDecimalNumber(decimal: record.value).doubleValue))
                            PointMark(x: .value("Дата", record.measuredAt), y: .value(kind.unit, NSDecimalNumber(decimal: record.value).doubleValue))
                        }.chartYScale(domain: .automatic(includesZero: false)).frame(height: 160)
                            .accessibilityLabel("История измерений: " + kind.title)
                    }
                }
                Section("История") {
                    ForEach(selected) { record in
                        Button { UsageTelemetry.shared.action("Measurements.edit"); editing = record } label: {
                            HStack {
                                Text(record.measuredAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.primary)
                                Spacer()
                                Text(Numbers.display(record.value, places: 2) + " " + kind.unit).foregroundStyle(.primary).monospacedDigit()
                            }
                        }.swipeActions {
                            Button(role: .destructive) { UsageTelemetry.shared.action("Measurements.delete"); remove(record) } label: { Label("Удалить", systemImage: "trash") }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Пока нет измерений", systemImage: kind == .weight ? "scalemass" : "ruler", description: Text("Добавь первое измерение. Можно указать любую прошедшую дату."))
            }
            Section { Text("Здесь — твои ручные измерения. История из Apple Здоровья хранится отдельно и не перезаписывает их.").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Измерения")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { UsageTelemetry.shared.action("Measurements.add"); adding = true } label: { Label("Добавить", systemImage: "plus") }
            }
        }
        .task { reload() }
        .sheet(isPresented: $adding) { MeasurementEditor(kind: kind, existing: nil) { reload() } }
        .sheet(item: $editing) { record in MeasurementEditor(kind: record.kind, existing: record) { reload() } }
        .usagePresentation("bodyMeasurements", visible: true)
    }
    private func reload() {
        do { records = try MeasurementRepository(container: diary.container).all(); error = nil }
        catch { self.error = "Не удалось прочитать измерения: " + error.localizedDescription }
    }
    private func remove(_ record: BodyMeasurement) {
        do { try MeasurementRepository(container: diary.container).delete(record.id); reload() }
        catch { self.error = "Не удалось удалить измерение: " + error.localizedDescription }
    }
}
private struct MeasurementEditor: View {
    @Environment(DiaryStore.self) private var diary
    @Environment(\.dismiss) private var dismiss
    @State var kind: MeasurementKind
    let existing: BodyMeasurement?
    var onSave: () -> Void
    @State private var value = ""
    @State private var date = Date()
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Picker("Измерение", selection: $kind) {
                    ForEach(MeasurementKind.allCases) { Text($0.title).tag($0) }
                }.disabled(existing != nil)
                HStack {
                    TextField("Значение", text: $value).keyboardType(.decimalPad).focused($focused).accessibilityLabel(kind.title)
                    Text(kind.unit).foregroundStyle(.secondary)
                }
                DatePicker("Когда измерено", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                if let error { Text(error).foregroundStyle(.red) }
            }.scrollDismissesKeyboard(.interactively)
            .navigationTitle(existing == nil ? "Новое измерение" : "Измерение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { UsageTelemetry.shared.action("Measurements.cancel"); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { UsageTelemetry.shared.action("Measurements.save"); save() }.disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { if let existing { value = Numbers.string(existing.value); date = existing.measuredAt }; focused = true }
        }.usagePresentation("measurementEditor", visible: true)
    }
    private func save() {
        guard let parsed = try? Numbers.parse(value, positive: true), parsed <= 1000 else {
            error = "Введи число больше нуля, не больше 1000."; return
        }
        do {
            var record = existing ?? BodyMeasurement(kind: kind, value: 0, measuredAt: date)
            record.kind = kind; record.value = parsed; record.measuredAt = date
            try MeasurementRepository(container: diary.container).save(record)
            UsageTelemetry.shared.event("measurementSaved", ["kind": kind.rawValue, "id": record.id.uuidString])
            onSave(); dismiss()
        } catch { self.error = "Не удалось сохранить измерение. Данные оставлены в форме — попробуй ещё раз." }
    }
}

struct QuickMeasurementsView: View {
    @Environment(DiaryStore.self) private var diary
    @Environment(\.dismiss) private var dismiss
    @State private var weight = ""
    @State private var waist = ""
    @State private var previous: [BodyMeasurement] = []
    @State private var error: String?
    @State private var loaded = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field(.weight, text: $weight)
                    field(.waist, text: $waist)
                } footer: {
                    Text("Заполни только то, что измерил сейчас. Остальное останется с прошлого раза.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Измерения сейчас")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { UsageTelemetry.shared.action("QuickMeasurements.cancel"); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { UsageTelemetry.shared.action("QuickMeasurements.save"); save() }
                        .disabled(!loaded || (weight.trimmingCharacters(in: .whitespaces).isEmpty && waist.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .onAppear {
                do { previous = try MeasurementRepository(container: diary.container).all(); loaded = true }
                catch { self.error = "Не удалось загрузить прошлые измерения. Закрой и открой форму ещё раз." }
            }
        }.presentationDetents([.large]).usagePresentation("quickMeasurements", visible: true)
    }
    private func field(_ kind: MeasurementKind, text: Binding<String>) -> some View {
        let last = previous.first { $0.kind == kind }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(kind.title)
                Spacer()
                QuickMeasurementField(text: text,
                    placeholder: last.map { Numbers.display($0.value, places: 2) } ?? "—",
                    title: kind.title, initiallyFocused: kind == .weight)
                    .frame(minHeight: 34)
                Text(kind.unit).foregroundStyle(.secondary)
            }
            if let last {
                Text("Последнее: " + Numbers.display(last.value, places: 2) + " " + kind.unit + " · " + last.measuredAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
    private func save() {
        let now = Date(), entryID = UUID()
        var values: [BodyMeasurement] = []
        for (kind, text) in [(MeasurementKind.weight, weight), (.waist, waist)] {
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let value = try? Numbers.parse(text, positive: true), value <= 1000 else {
                error = kind.title + ": введи число больше нуля, не больше 1000."; return
            }
            var record = BodyMeasurement(kind: kind, value: value, measuredAt: now)
            record.entryID = entryID; values.append(record)
        }
        do {
            try MeasurementRepository(container: diary.container).saveEntry(values)
            UsageTelemetry.shared.event("measurementEntrySaved", ["id": entryID.uuidString, "count": String(values.count)])
            dismiss()
        } catch { self.error = "Не удалось сохранить. Значения остались в форме — попробуй ещё раз." }
    }
}

/// Focus is requested when UIKit attaches the field to the presentation window,
/// rather than after SwiftUI's sheet appearance/focus-state update.
private struct QuickMeasurementField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let title: String
    let initiallyFocused: Bool
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeUIView(context: Context) -> PresentationTextField {
        let field = PresentationTextField()
        field.initiallyFocused = initiallyFocused
        field.keyboardType = .decimalPad
        field.textAlignment = .right
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.accessibilityLabel = title
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }
    func updateUIView(_ field: PresentationTextField, context: Context) {
        context.coordinator.text = $text
        if field.text != text { field.text = text }
        field.placeholder = placeholder
    }
    static func dismantleUIView(_ field: PresentationTextField, coordinator: Coordinator) {
        if field.isFirstResponder { field.resignFirstResponder() }
    }
    final class Coordinator: NSObject {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
    }
    final class PresentationTextField: UITextField {
        var initiallyFocused = false
        private var requestedFocus = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, initiallyFocused, !requestedFocus else { return }
            requestedFocus = true
            becomeFirstResponder()
        }
    }
}
