import SwiftUI
import HealthKit
import Charts

@MainActor @Observable final class HealthSleep {
    static let shared = HealthSleep()
    private let store = HKHealthStore()
    private let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    private let quantities: [(HKQuantityTypeIdentifier, String)] = [
        (.stepCount, "Шаги"), (.activeEnergyBurned, "Активная энергия"), (.basalEnergyBurned, "Энергия покоя"),
        (.distanceWalkingRunning, "Ходьба и бег"), (.appleExerciseTime, "Время упражнений"),
        (.heartRate, "Пульс"), (.restingHeartRate, "Пульс покоя"), (.walkingHeartRateAverage, "Пульс при ходьбе"),
        (.heartRateVariabilitySDNN, "Вариабельность пульса"), (.respiratoryRate, "Дыхание"),
        (.oxygenSaturation, "Кислород крови"), (.vo2Max, "VO₂ max"), (.bodyMass, "Вес"),
        (.bodyFatPercentage, "Процент жира"), (.leanBodyMass, "Безжировая масса")]
    var wake: Date? { estimate?.date }
    var estimate: WakeEstimate?
    var loading = false
    var status = "Не подключено"
    var syncStatus = ""
    var lastRead: Date?
    var steps: Double?
    var activeEnergy: Double?
    var restingEnergy: Double?
    var latestSleep: Date?
    var nights: [SleepNight] = []
    var days: [HealthDay] = []
    var workouts: [WorkoutBrief] = []
    var overviewError: String?
    struct WorkoutBrief: Identifiable, Codable {
        var id: UUID
        var date: Date
        var minutes: Double
        var name: String
        var source: String
    }
    @ObservationIgnored private var activityDay: Day?
    @ObservationIgnored private var archiveTask: Task<Void, Never>?
    var enabled: Bool { UserDefaults.standard.bool(forKey: "planner.healthSleep") }
    var expanded: Bool { UserDefaults.standard.bool(forKey: "health.expanded") }
    var requestedTypes: [(HKSampleType, String)] {
        var result: [(HKSampleType, String)] = [(type, "Сон")]
        if expanded {
            result += quantities.compactMap { id, title in HKObjectType.quantityType(forIdentifier: id).map { ($0, title) } }
            result.append((HKObjectType.workoutType(), "Тренировки"))
        }
        return result
    }
    func connect() async {
        guard HKHealthStore.isHealthDataAvailable() else { status = "Данные здоровья недоступны"; return }
        var read: Set<HKObjectType> = [type, HKObjectType.workoutType()]
        for (id, _) in quantities { if let value = HKObjectType.quantityType(forIdentifier: id) { read.insert(value) } }
        do {
            try await store.requestAuthorization(toShare: [], read: read)
            UserDefaults.standard.set(true, forKey: "planner.healthSleep")
            UserDefaults.standard.set(true, forKey: "health.expanded")
            await refresh()
        } catch { status = "Не удалось запросить доступ. Попробуй ещё раз." }
    }
    func disconnect() {
        UserDefaults.standard.set(false, forKey: "planner.healthSleep")
        archiveTask?.cancel()
        estimate = nil; steps = nil; activeEnergy = nil; restingEnergy = nil
        nights = []; days = []; workouts = []
        status = "Не подключено"; syncStatus = "Синхронизация выключена. Локальный архив сохранён."
    }
    func pauseArchive() { archiveTask?.cancel() }
    func refresh() async {
        guard enabled, !loading, HKHealthStore.isHealthDataAvailable() else { return }
        loading = true
        defer { loading = false }
        let now = Date()
        if activityDay != Day(now) {
            steps = nil; activeEnergy = nil; restingEnergy = nil; activityDay = Day(now)
        }
        do {
            let predicate = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-31 * 86400), end: now)
            let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: samples as? [HKCategorySample] ?? []) }
                }
                store.execute(query)
            }
            guard enabled else { return }
            let asleep = samples.filter { [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue].contains($0.value) }
            latestSleep = asleep.map(\.endDate).max()
            let intervals = asleep.map { DateInterval(start: $0.startDate, end: $0.endDate) }
            estimate = WakeEstimate.calculate(intervals: intervals, now: now)
            nights = HealthInsights.nights(intervals, now: now).filter { $0.end >= Calendar.autoupdatingCurrent.date(byAdding: .day, value: -28, to: now)! }
            lastRead = now
            if let estimate {
                status = (estimate.observed ? "Сон закончился около " : "Ожидаем пробуждение около ") + estimate.date.formatted(date: .omitted, time: .shortened)
            } else { status = "Пока недостаточно доступной истории сна" }
            if expanded {
                let newSteps = try await sum(.stepCount, unit: .count(), now: now)
                guard enabled else { return }
                let newActive = try await sum(.activeEnergyBurned, unit: .kilocalorie(), now: now)
                guard enabled else { return }
                let newResting = try await sum(.basalEnergyBurned, unit: .kilocalorie(), now: now)
                guard enabled else { return }
                steps = newSteps; activeEnergy = newActive; restingEnergy = newResting
                do {
                    let stepDays = try await daily(.stepCount, unit: .count(), now: now)
                    let activeDays = try await daily(.activeEnergyBurned, unit: .kilocalorie(), now: now)
                    let restDays = try await daily(.basalEnergyBurned, unit: .kilocalorie(), now: now)
                    let recentWorkouts = try await readWorkouts(now: now)
                    guard enabled else { return }
                    let calendar = Calendar.autoupdatingCurrent
                    let today = calendar.startOfDay(for: now)
                    days = (1...28).reversed().map { offset in
                        let date = calendar.date(byAdding: .day, value: -offset, to: today)!
                        return HealthDay(date: date, steps: stepDays[date], activeEnergy: activeDays[date], restingEnergy: restDays[date])
                    }
                    workouts = recentWorkouts; overviewError = nil
                    let snapshot = InsightSnapshot(readAt: now, days: days, workouts: workouts)
                    try await HealthArchive.shared.saveOverview(try JSONEncoder().encode(snapshot))
                } catch { overviewError = "История обновилась не полностью. Попробуй обновить ещё раз." }

            }
            guard enabled else { steps = nil; activeEnergy = nil; restingEnergy = nil; return }
            UsageTelemetry.shared.event("healthRead", ["sleepSamples": String(samples.count), "wakeSource": estimate.map { $0.observed ? "observed" : "history" } ?? "unavailable", "historyDays": String(estimate?.days ?? 0)])
        } catch {
            // Preserve an in-memory estimate only for the same day; label failed refresh explicitly.
            if estimate.map({ Day($0.date) != Day(now) }) == true { estimate = nil }
            status = "Не удалось обновить данные. Показаны предыдущие доступные сведения."
            UsageTelemetry.shared.event("healthReadFailed", ["error": error.localizedDescription])
        }
        startArchive()
    }
    private struct InsightSnapshot: Codable {
        var readAt: Date
        var days: [HealthDay]
        var workouts: [WorkoutBrief]
    }
    private func daily(_ id: HKQuantityTypeIdentifier, unit: HKUnit, now: Date) async throws -> [Date: Double] {
        let type = HKObjectType.quantityType(forIdentifier: id)!
        let calendar = Calendar.autoupdatingCurrent
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -28, to: end)!
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error { continuation.resume(throwing: error); return }
                var values: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    if statistics.startDate < end, let quantity = statistics.sumQuantity() {
                        values[statistics.startDate] = quantity.doubleValue(for: unit)
                    }
                }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }
    private func readWorkouts(now: Date) async throws -> [WorkoutBrief] {
        let start = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -28, to: now)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let values = (samples as? [HKWorkout] ?? []).map { workout in
                    let name: String
                    switch workout.workoutActivityType {
                    case .walking: name = "Ходьба"
                    case .running: name = "Бег"
                    case .traditionalStrengthTraining, .functionalStrengthTraining: name = "Силовая"
                    case .cycling: name = "Велосипед"
                    case .swimming: name = "Плавание"
                    case .yoga: name = "Йога"
                    case .highIntensityIntervalTraining: name = "Интервальная"
                    default: name = "Тренировка"
                    }
                    return WorkoutBrief(id: workout.uuid, date: workout.startDate, minutes: workout.duration / 60,
                        name: name, source: workout.sourceRevision.source.name)
                }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }
    private func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, now: Date) async throws -> Double? {
        let quantity = HKObjectType.quantityType(forIdentifier: id)!
        let start = Calendar.autoupdatingCurrent.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: quantity, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: unit)) }
            }
            store.execute(query)
        }
    }
    private func startArchive() {
        guard enabled, archiveTask == nil else { return }
        archiveTask = Task {
            defer { archiveTask = nil }
            var failures = 0
            for (type, title) in requestedTypes {
                guard !Task.isCancelled, enabled else { return }
                do {
                    let previous = try await HealthArchive.shared.latest(type.identifier)
                    var anchor: HKQueryAnchor? = try previous.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0.anchor) }
                    var count = 0
                    while !Task.isCancelled && enabled {
                        syncStatus = "Сохраняем: " + title + (count > 0 ? " · \(count) записей" : "")
                        let page: (samples: [HKSample], deleted: [HKDeletedObject], anchor: HKQueryAnchor?) = try await withCheckedThrowingContinuation { continuation in
                            let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: 500) { _, samples, deleted, anchor, error in
                                if let error { continuation.resume(throwing: error) }
                                else { continuation.resume(returning: (samples ?? [], deleted ?? [], anchor)) }
                            }
                            store.execute(query)
                        }
                        guard !Task.isCancelled, enabled else { return }
                        guard let next = page.anchor else { break }
                        let cursor = try NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true)
                        // Empty refresh with unchanged cursor needs no new archive file.
                        if !page.samples.isEmpty || !page.deleted.isEmpty || previous?.anchor != cursor {
                            let payload = try NSKeyedArchiver.archivedData(withRootObject: page.samples, requiringSecureCoding: true)
                            try await HealthArchive.shared.save(.init(type: type.identifier, receivedAt: Date(), anchor: cursor,
                                samples: payload, added: page.samples.count, deletedIDs: page.deleted.map(\.uuid)))
                            UsageTelemetry.shared.event("healthArchiveBatch", ["type": type.identifier, "added": String(page.samples.count), "deleted": String(page.deleted.count)])
                        }
                        anchor = next; count += page.samples.count
                        if page.samples.count + page.deleted.count < 500 { break }
                        await Task.yield()
                    }
                } catch {
                    failures += 1
                    UsageTelemetry.shared.event("healthArchiveFailed", ["type": type.identifier, "error": error.localizedDescription])
                }
            }
            syncStatus = failures == 0 ? "Доступные записи сохранены локально" : "Не все разделы обновились. Повторим при следующем открытии."
        }
    }
}

struct HealthDataView: View {
    private var week: [HealthDay] { Array(HealthSleep.shared.days.suffix(7)) }
    private var todayEnergy: Double? {
        guard let active = HealthSleep.shared.activeEnergy, let resting = HealthSleep.shared.restingEnergy else { return nil }
        return active + resting
    }
    private func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let minutes = Int(seconds / 60)
        return "\(minutes / 60) ч \(minutes % 60) мин"
    }
    private func insight(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
    var body: some View {
        Form {
            Section("Сон и пробуждение") {
                Text(HealthSleep.shared.status).font(.headline)
                if let estimate = HealthSleep.shared.estimate, !estimate.observed {
                    LabeledContent("Источник", value: "История · \(estimate.days) дней")
                    LabeledContent("Обычный диапазон", value: estimate.earliest.formatted(date: .omitted, time: .shortened) + "–" + estimate.latest.formatted(date: .omitted, time: .shortened))
                    Text("Это прогноз, не факт пробуждения. Сегодняшний сон может появиться после синхронизации браслета.").font(.footnote).foregroundStyle(.secondary)
                }
                if let date = HealthSleep.shared.latestSleep {
                    LabeledContent("Последняя запись сна", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("Сон · последние ночи") {
                let nights = Array(HealthSleep.shared.nights.suffix(7))
                if !nights.isEmpty {
                    HStack(alignment: .top) {
                        insight("В среднем спишь", duration(HealthInsights.mean(nights.map { Optional($0.seconds) })))
                        Spacer()
                        insight("Засыпаешь", HealthInsights.meanClock(nights.map(\.start)) ?? "Разный ритм")
                        Spacer()
                        insight("Просыпаешься", HealthInsights.meanClock(nights.map(\.end)) ?? "Разный ритм")
                    }
                    Chart(nights) { night in
                        BarMark(x: .value("Ночь", night.end, unit: .day), y: .value("Часы сна", night.seconds / 3600))
                            .foregroundStyle(.indigo).cornerRadius(3)
                    }.frame(height: 100).chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.day()) } }
                        .accessibilityLabel("Длительность сна по последним ночам")
                    Text("\(nights.count) ночей с данными. Считаем сон, а не время в постели.").font(.caption).foregroundStyle(.secondary)
                } else { Text("Пока нет доступных ночей сна").foregroundStyle(.secondary) }
            }
            Section("Шаги") {
                HStack(alignment: .top) {
                    insight("Сегодня, пока", HealthSleep.shared.steps.map { String(Int($0)) } ?? "—")
                    Spacer()
                    insight("В среднем за день", HealthInsights.mean(week.map(\.steps)).map { String(Int($0)) } ?? "—")
                }
                if week.contains(where: { $0.steps != nil }) {
                    Chart(week.filter { $0.steps != nil }) { day in
                        BarMark(x: .value("День", day.date, unit: .day), y: .value("Шаги", day.steps!))
                            .foregroundStyle(.green).cornerRadius(3)
                    }.frame(height: 100).chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                        .accessibilityLabel("Шаги за предыдущие семь дней")
                }
                Text("Среднее: \(week.filter { $0.steps != nil }.count) из 7 прошедших дней с данными. Пропуски не считаются нулями.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Расход энергии") {
                HStack(alignment: .top) {
                    insight("Сегодня, пока", todayEnergy.map { "≈\(Int($0)) ккал" } ?? "—")
                    Spacer()
                    insight("Среднее за день", HealthInsights.mean(week.map(\.totalEnergy)).map { "≈\(Int($0)) ккал" } ?? "—")
                }
                LabeledContent("Активная сегодня", value: HealthSleep.shared.activeEnergy.map { "\(Int($0)) ккал" } ?? "Нет данных")
                LabeledContent("В покое сегодня", value: HealthSleep.shared.restingEnergy.map { "\(Int($0)) ккал" } ?? "Нет данных")
                Text("Покой + активность по Здоровью. Среднее по \(week.filter { $0.totalEnergy != nil }.count) из 7 прошедших дней. Это оценка устройства: пропуски и погрешность влияют на результат. Тренировки отдельно не прибавляем; цели не меняем.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Тренировки · 28 дней") {
                if HealthSleep.shared.workouts.isEmpty {
                    Text("Нет доступных записей").foregroundStyle(.secondary)
                } else {
                    Text("\(HealthSleep.shared.workouts.count) записей тренировок").font(.headline)
                    ForEach(HealthSleep.shared.workouts.prefix(5)) { workout in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(workout.name)
                                Text(workout.date.formatted(date: .abbreviated, time: .shortened) + " · " + workout.source)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(workout.minutes)) мин").monospacedDigit()
                        }
                    }
                }
            }
            if let error = HealthSleep.shared.overviewError {
                Section { Text(error).foregroundStyle(.secondary) }
            }
            Section("Синхронизация") {
                if let date = HealthSleep.shared.lastRead { LabeledContent("Последнее чтение", value: date.formatted(date: .omitted, time: .shortened)) }
                if !HealthSleep.shared.syncStatus.isEmpty { Text(HealthSleep.shared.syncStatus).font(.subheadline) }
                Button("Разрешить данные Здоровья") {
                    UsageTelemetry.shared.action("Profile.sleepConnect")
                    Task { await HealthSleep.shared.connect() }
                }.disabled(HealthSleep.shared.loading)
                Button("Обновить") {
                    UsageTelemetry.shared.action("Health.refresh")
                    Task { await HealthSleep.shared.refresh() }
                }.disabled(HealthSleep.shared.loading || !HealthSleep.shared.enabled)
                if HealthSleep.shared.enabled {
                    Button("Отключить синхронизацию") {
                        UsageTelemetry.shared.action("Profile.sleepDisconnect")
                        HealthSleep.shared.disconnect()
                    }
                }
                Text("Читаем разрешённые сон, шаги, энергию, ходьбу, упражнения, тренировки, пульс, вариабельность, дыхание, кислород, VO₂ max и состав тела. История сохраняется на iPhone порциями, с учётом исправлений и удалений источника. Первый импорт может занять время; продолжение — при открытом приложении.").font(.footnote).foregroundStyle(.secondary)
                Text("Пустые данные могут означать задержку синхронизации или отсутствие разрешения. Доступ к каждому показателю можно изменить в Apple Здоровье.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Здоровье").navigationBarTitleDisplayMode(.inline)
            .task { await HealthSleep.shared.refresh() }
            .usagePresentation("health", visible: true)
    }
}
