import Foundation
import SwiftData

/// Optional manual handoff check. Always migrate/read an independent copy, never the source backup.
@MainActor func checkPlannerSnapshot(source: URL, destination: URL) async throws {
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw CocoaError(.fileWriteFileExists)
    }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: destination)
    let container = try DiaryStore.makeContainer(url: destination)
    let store = DiaryStore(container: container, catalog: Catalog(url: nil))
    try store.reload()
    let day = store.today
    let page = try await MealRepository(container: container).page(for: day)
    guard store.error == nil, store.readIssues.isEmpty, page.issues.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
    let settings = ProcessInfo.processInfo.environment
    let interval = Double(settings["CACALC_VERIFY_INTERVAL"] ?? "4") ?? 4
    let bedtime = Int(settings["CACALC_VERIFY_BEDTIME"] ?? "23") ?? 23
    let wake = settings["CACALC_VERIFY_WAKE"].flatMap { ISO8601DateFormatter().date(from: $0) }
    let result = AdaptiveMealPlan.calculate(page: page, day: day, intervalHours: interval, bedtimeHour: bedtime,
                                          history: store.mealHistory, wakeTime: wake)
    guard result.suggestions.allSatisfy({ $0.start < $0.end }),
          zip(result.suggestions, result.suggestions.dropFirst()).allSatisfy({ $0.end <= $1.start }) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let context = ModelContext(container)
    let calendar = Calendar.autoupdatingCurrent
    let entryTime = calendar.date(bySettingHour: 11, minute: 28, second: 0, of: day.date)!
    let proposed = MealEntrySuggestion.choose(page: page, day: day, now: entryTime, intervalHours: interval,
                                              bedtimeHour: bedtime, history: store.mealHistory, wakeTime: wake)
    let report: [String: Any] = ["day": day.rawValue, "ruleVersion": AdaptiveMealPlan.ruleVersion,
        "entryRuleVersion": MealEntrySuggestion.ruleVersion, "entryAt1128": proposed.rawValue,
        "todayRows": page.items.count, "historyRows": store.mealHistory.count,
        "journalRows": try context.fetchCount(FetchDescriptor<PersonalSchemaV3.JournalRecord>()),
        "independentDrafts": try context.fetchCount(FetchDescriptor<PersonalSchemaV8.WorkDraft>()),
        "suggestions": result.suggestions.map { ["meal": $0.meal.rawValue,
            "start": $0.start.formatted(date: .omitted, time: .shortened),
            "end": $0.end.formatted(date: .omitted, time: .shortened)] }]
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        .write(to: destination.deletingLastPathComponent().appendingPathComponent("planner-verification.json"))
    print("PASS: independent snapshot migrated, real diary/history decoded and ordered planner calculated")
}

@MainActor func checkMealPlanning() async throws {
    func check(_ value: Bool, _ message: String) { if !value { FileHandle.standardError.write(Data(("CHECK FAILED: " + message + "\n").utf8)); fatalError(message) } }
    let creamContainer = try DiaryStore.makeContainer(memory: true)
    let creamDB = ModelContext(creamContainer)
    let preservedDraft = try JSONEncoder().encode(ProductCreationDraft())
    creamDB.insert(PersonalSchemaV2.ProductDraftRecord(preservedDraft))
    try creamDB.save()
    check(try CreamTableImport.apply(to: creamContainer) == 7, "seven cream cards imported atomically")
    let creamProducts = try await ProductRepository(container: creamContainer).search("Сливки", limit: nil)
    let creamExpected: [(Int, String, String, String, String)] = [
        (10, "119", "2.7", "10", "4.2"), (15, "161", "2.6", "15", "3.9"),
        (20, "206", "2.6", "20", "4.0"), (22, "224", "2.5", "22", "4.0"),
        (25, "250", "2.4", "25", "3.5"), (30, "297", "2.2", "30", "4.5"),
        (33, "319", "2.2", "33", "3.2")]
    check(creamProducts.count == 7, "seven cream cards readable through personal search")
    for (percent, calories, protein, fat, carbs) in creamExpected {
        let product = creamProducts.first { $0.name == "Сливки \(percent)%" }
        check(product?.brand == "" && product?.barcode == nil && product?.basis == .g && product?.source == "user-label",
              "cream identity and per-100-g basis")
        check(product?.calories == Decimal(string: calories) && product?.protein == Decimal(string: protein)
              && product?.fat == Decimal(string: fat) && product?.carbs == Decimal(string: carbs),
              "cream nutrition from user table")
    }
    check(try CreamTableImport.apply(to: creamContainer) == 0, "cream import is idempotent")
    check(try ModelContext(creamContainer).fetch(FetchDescriptor<PersonalSchemaV2.ProductDraftRecord>()).first?.data == preservedDraft,
          "cream import preserves an unfinished product draft")
    let conflictContainer = try DiaryStore.makeContainer(memory: true)
    let conflictDB = ModelContext(conflictContainer)
    let existingCream = Product(id: UUID().uuidString, barcode: nil, name: "Сливки 10%", brand: "", basis: .g,
                                calories: 1, protein: 1, fat: 1, carbs: 1, source: "user-label")
    conflictDB.insert(PersonalSchema.PersonalProduct(existingCream, data: try JSONEncoder().encode(existingCream)))
    try conflictDB.save()
    do { _ = try CreamTableImport.apply(to: conflictContainer); preconditionFailure("cream conflict must stop import") } catch {}
    check(try ModelContext(conflictContainer).fetchCount(FetchDescriptor<PersonalSchema.PersonalProduct>()) == 1,
          "conflict leaves existing card untouched and adds nothing")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cacalc-planner-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let day = Day(Date())
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    func at(_ hour: Int, _ minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day.date)! }
    let windows: [AdaptiveMealPlan.Suggestion] = [
        .init(meal: .breakfast, start: at(8), end: at(10), nutrition: .unknown),
        .init(meal: .lunch, start: at(13), end: at(15), nutrition: .unknown),
        .init(meal: .dinner, start: at(19), end: at(21), nutrition: .unknown)]
    let earlyLunchWindows: [AdaptiveMealPlan.Suggestion] = [
        .init(meal: .breakfast, start: at(7), end: at(9), nutrition: .unknown),
        .init(meal: .lunch, start: at(11), end: at(13), nutrition: .unknown),
        .init(meal: .dinner, start: at(17), end: at(19), nutrition: .unknown)]
    check(MealEntrySuggestion.choose(windows: earlyLunchWindows, eaten: [], at: at(11, 28)) == .breakfast,
          "first meal at 11:28 is breakfast even inside the historical lunch window")
    for hour in [6, 9, 11, 13, 16, 20, 23] {
        check(MealEntrySuggestion.choose(windows: windows, eaten: [], at: at(hour, 28)) == .breakfast,
              "a late first meal does not become lunch, dinner or snack: \(hour):28")
    }
    check(MealEntrySuggestion.choose(windows: [], eaten: [], at: at(11, 28)) == .breakfast,
          "first meal does not require an available historical window")
    check(MealEntrySuggestion.choose(windows: earlyLunchWindows, eaten: [.snack], at: at(11, 28)) == .breakfast,
          "an earlier snack does not complete breakfast")
    check(MealEntrySuggestion.choose(windows: earlyLunchWindows, eaten: [.breakfast], at: at(11, 28)) == .lunch,
          "an already consumed breakfast allows lunch near its window")
    check(MealEntrySuggestion.choose(windows: earlyLunchWindows, eaten: [.breakfast], at: at(17)) == .snack,
          "clock proximity cannot skip an unconsumed lunch and select dinner")
    check(MealEntrySuggestion.choose(windows: windows, eaten: [.lunch], at: at(19)) == .dinner,
          "an explicitly consumed lunch does not recreate the skipped breakfast")
    check(MealEntrySuggestion.choose(windows: windows, eaten: [.breakfast], at: at(16)) == .lunch, "late missing lunch")
    check(MealEntrySuggestion.choose(windows: windows, eaten: [.breakfast, .lunch], at: at(17).addingTimeInterval(28 * 60)) == .snack, "17:28 before distant dinner is snack")
    check(MealEntrySuggestion.choose(windows: windows, eaten: [.breakfast, .lunch], at: at(19)) == .dinner, "inside dinner window")
    check(MealEntrySuggestion.choose(windows: windows, eaten: Set(Meal.currentCases), at: at(20)) == .snack, "completed meals are not suggested again")
    // Regression: independent historical clocks and bedtime fallback inverted lunch/dinner.
    func timedItem(_ meal: Meal, day itemDay: Day, hour: Int, minute: Int = 0) -> DiaryItem {
        let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: itemDay.date)!
        var row = MealRow(food: "Синтетический " + meal.title)
        row.timing = MealTiming(mode: .earlier, selectedAt: date, consumedAt: date, source: "synthetic")
        return DiaryItem(id: row.id, day: itemDay, meal: meal, row: row)
    }
    let earlyHistory = (1...3).flatMap { offset in
        [timedItem(.breakfast, day: day.offset(-offset), hour: 7),
         timedItem(.lunch, day: day.offset(-offset), hour: 11),
         timedItem(.dinner, day: day.offset(-offset), hour: 17)]
    }
    var plannedLunch = timedItem(.lunch, day: day, hour: 12)
    plannedLunch.row.timing?.mode = .planned; plannedLunch.row.timing?.consumedAt = nil
    for items in [[], [timedItem(.snack, day: day, hour: 8)], [plannedLunch]] {
        check(MealEntrySuggestion.choose(page: .init(items: items, goals: nil), day: day, now: at(11, 28),
                                        intervalHours: 4, bedtimeHour: 23, history: earlyHistory, wakeTime: nil) == .breakfast,
              "real chooser starts with breakfast despite early history, snack or a fixed lunch plan")
    }
    check(MealEntrySuggestion.choose(page: .init(items: [], goals: nil), day: day, now: at(11, 28),
                                    intervalHours: 4, bedtimeHour: 23, history: earlyHistory, wakeTime: at(7, 12)) == .breakfast,
          "early Health sleep does not turn the first meal at 11:28 into lunch")
    let entryContainer = try DiaryStore.makeContainer(memory: true)
    let entryStore = DiaryStore(container: entryContainer, catalog: Catalog(url: nil))
    let entrySession = MealSession(store: entryStore, diagnosticLog: MatchingLog(directory: directory.appendingPathComponent("entry-logs")))
    await entrySession.begin(day: day, now: at(11, 28))
    check(entrySession.draft?.meal == .breakfast && entrySession.draft?.timing?.startedAt == at(11, 28),
          "the actual new-entry route opens breakfast at 11:28 without a clock fallback")
    entrySession.addManual(name: "Синтетический завтрак")
    try await entrySession.flush()
    let firstDraft = entrySession.draft!
    let resumedEntry = MealSession(store: entryStore, diagnosticLog: MatchingLog(directory: directory.appendingPathComponent("resumed-entry-logs")))
    await resumedEntry.load()
    check(resumedEntry.draft?.id == firstDraft.id && resumedEntry.draft?.meal == .breakfast,
          "resuming preserves the selected first meal")
    await resumedEntry.begin(day: day, meal: .snack, now: at(11, 28))
    check(resumedEntry.draft?.meal == .snack && resumedEntry.drafts.contains { $0.id == firstDraft.id && $0.meal == .breakfast },
          "explicit snack remains available without relabeling the breakfast draft")
    let entryRepository = MealRepository(container: entryContainer)
    try await entryRepository.commit(firstDraft, now: at(11, 28))
    let firstMealPage = try await entryRepository.page(for: day)
    let afterFirstMeal = AdaptiveMealPlan.calculate(page: firstMealPage, day: day, now: at(11, 28))
    check(firstMealPage.items.count == 1 && firstMealPage.items[0].meal == .breakfast
          && firstMealPage.items[0].row.timing?.consumedAt == at(11, 28),
          "first meal is saved and read as breakfast with its confirmed time")
    check(afterFirstMeal.suggestions.map(\.meal) == [.lunch, .dinner]
          && afterFirstMeal.suggestions[0].start == at(14, 28) && afterFirstMeal.suggestions[0].end == at(16, 28)
          && afterFirstMeal.suggestions[1].start == at(18, 28) && afterFirstMeal.suggestions[1].end == at(20, 28),
          "11:28 breakfast anchors lunch and dinner four hours apart")
    await resumedEntry.begin(day: day, now: at(15, 28))
    check(resumedEntry.draft?.meal == .lunch, "automatic entry reads the newly saved breakfast before choosing lunch")
    await resumedEntry.begin(day: day, item: firstMealPage.items[0], now: at(17))
    check(resumedEntry.draft?.meal == .breakfast && resumedEntry.draft?.timing?.consumedAt == at(11, 28),
          "editing a saved breakfast does not reclassify it at the current clock time")
    print("PASS: first meal at 11:28, main-meal sequence, explicit snack, draft recovery and real save/read/next-entry route")
    let lateBreakfastPage = DiaryPageData(items: [timedItem(.breakfast, day: day, hour: 13)], goals: nil)
    let invertedHistory = (1...3).flatMap { offset in
        [timedItem(.breakfast, day: day.offset(-offset), hour: 9),
         timedItem(.lunch, day: day.offset(-offset), hour: 21),
         timedItem(.dinner, day: day.offset(-offset), hour: 19)]
    }
    let orderedLateDay = AdaptiveMealPlan.calculate(page: lateBreakfastPage, day: day, now: at(17), history: invertedHistory)
    check(orderedLateDay.suggestions.map(\.meal) == [.lunch, .dinner], "remaining meals retain breakfast/lunch/dinner order")
    check(orderedLateDay.suggestions[0].end <= orderedLateDay.suggestions[1].start,
          "late historical lunch and bedtime cannot put dinner before today's lunch")
    check(orderedLateDay.suggestions[0].start == at(16) && orderedLateDay.suggestions[0].end == at(18),
          "today's 13:00 breakfast anchors lunch around 17:00 despite historical clocks")
    check(orderedLateDay.suggestions[1].start == at(20) && orderedLateDay.suggestions[1].end == at(22),
          "dinner follows today's lunch around 21:00")
    check(MealEntrySuggestion.choose(page: lateBreakfastPage, day: day, now: at(17), intervalHours: 4,
                                    bedtimeHour: 23, history: invertedHistory, wakeTime: nil) == .lunch,
          "the real entry chooser selects lunch at 17:00 after a late breakfast")
    let atNight = AdaptiveMealPlan.calculate(page: lateBreakfastPage, day: day, now: at(23), history: invertedHistory)
    check(zip(orderedLateDay.suggestions, atNight.suggestions).allSatisfy { $0.start == $1.start && $0.end == $1.end },
          "passing clock time cannot move or invert today's anchored windows")
    let normalHistory = (1...5).flatMap { offset in
        [timedItem(.breakfast, day: day.offset(-offset), hour: 9),
         timedItem(.lunch, day: day.offset(-offset), hour: offset == 1 ? 21 : 14),
         timedItem(.dinner, day: day.offset(-offset), hour: 20)]
    }
    let afterOneLateDay = AdaptiveMealPlan.calculate(page: lateBreakfastPage, day: day, now: at(17), history: normalHistory)
    check(zip(orderedLateDay.suggestions, afterOneLateDay.suggestions).allSatisfy { first, second in
        first.start.addingTimeInterval(first.end.timeIntervalSince(first.start) / 2)
            == second.start.addingTimeInterval(second.end.timeIntervalSince(second.start) / 2)
    }, "one late yesterday cannot override today's breakfast anchor")
    var lunchAtFive = lateBreakfastPage
    lunchAtFive.items.append(timedItem(.lunch, day: day, hour: 17))
    let afterActualLunch = AdaptiveMealPlan.calculate(page: lunchAtFive, day: day, now: at(17), history: invertedHistory)
    check(afterActualLunch.suggestions.map(\.meal) == [.dinner]
          && afterActualLunch.suggestions[0].start == at(20) && afterActualLunch.suggestions[0].end == at(22),
          "saving today's 17:00 lunch anchors dinner independently of yesterday")
    let extendedBreakfast = DiaryPageData(items: lateBreakfastPage.items + [timedItem(.breakfast, day: day, hour: 16, minute: 43)], goals: nil)
    let afterBreakfastAddition = AdaptiveMealPlan.calculate(page: extendedBreakfast, day: day, now: at(17), history: invertedHistory)
    check(zip(orderedLateDay.suggestions, afterBreakfastAddition.suggestions).allSatisfy { $0.start == $1.start && $0.end == $1.end },
          "later food appended to breakfast cannot reset its first known time or postpone lunch")
    var plannedSnack = timedItem(.snack, day: day, hour: 18)
    plannedSnack.row.timing?.mode = .planned; plannedSnack.row.timing?.consumedAt = nil
    let withPlannedSnack = AdaptiveMealPlan.calculate(page: .init(items: lateBreakfastPage.items + [plannedSnack], goals: nil),
                                                    day: day, now: at(17), history: invertedHistory)
    check(zip(orderedLateDay.suggestions, withPlannedSnack.suggestions).allSatisfy { $0.start == $1.start && $0.end == $1.end },
          "planned snacks cannot constrain or shift main-meal windows")
    var fixedDinner = timedItem(.dinner, day: day, hour: 20)
    fixedDinner.row.timing?.mode = .planned; fixedDinner.row.timing?.consumedAt = nil
    let withFixedDinner = AdaptiveMealPlan.calculate(page: .init(items: lateBreakfastPage.items + [fixedDinner], goals: nil),
                                                    day: day, now: at(17), history: invertedHistory)
    check(withFixedDinner.suggestions.map(\.meal) == [.lunch]
          && withFixedDinner.suggestions[0].start > at(13) && withFixedDinner.suggestions[0].end < at(20),
          "a fixed dinner limits only the preceding lunch and is not moved")
    let earlyLunch = AdaptiveMealPlan.calculate(page: .init(items: [timedItem(.lunch, day: day, hour: 7)], goals: nil),
                                               day: day, now: at(7))
    check(earlyLunch.suggestions.first?.meal == .breakfast && earlyLunch.suggestions.first!.end < at(7),
          "a known early lunch constrains breakfast without moving breakfast after lunch")
    let lateHistory = (1...3).flatMap { offset in
        [timedItem(.breakfast, day: day.offset(-offset), hour: 21),
         timedItem(.lunch, day: day.offset(-offset), hour: 9),
         timedItem(.dinner, day: day.offset(-offset), hour: 18)]
    }
    let orderedEmptyDay = AdaptiveMealPlan.calculate(page: .init(items: [], goals: nil), day: day, now: at(7), history: lateHistory)
    check(orderedEmptyDay.suggestions.map(\.meal) == Meal.currentCases
          && zip(orderedEmptyDay.suggestions, orderedEmptyDay.suggestions.dropFirst()).allSatisfy { $0.end <= $1.start },
          "historical clocks must also produce ordered windows before today's breakfast is known")
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day.date))!
    for breakfastHour in [6, 9, 13, 16, 19, 22, 23] {
        for interval in [2.0, 4.0, 6.0] {
            for bedtime in [18, 23] {
                let input = DiaryPageData(items: [timedItem(.breakfast, day: day, hour: breakfastHour)], goals: nil)
                let result = AdaptiveMealPlan.calculate(page: input, day: day, now: at(breakfastHour),
                                                      intervalHours: interval, bedtimeHour: bedtime, history: invertedHistory)
                check(result.suggestions.map(\.meal) == [.lunch, .dinner]
                      && result.suggestions.allSatisfy { $0.start > at(breakfastHour) && $0.start < $0.end && $0.end <= dayEnd }
                      && result.suggestions[0].end <= result.suggestions[1].start,
                      "late-day windows stay positive and ordered: breakfast=\(breakfastHour), interval=\(interval), bedtime=\(bedtime)")
            }
        }
    }
    print("PASS: ordered day windows, today's breakfast/lunch anchors, history outlier, bedtime compression, fixed dinner and entry chooser")
    let container = try DiaryStore.makeContainer(url: directory.appendingPathComponent("test.store"))
    let correctionDB = ModelContext(container)
    let correctionRow = MealRow(food: "Синтетический завтрак")
    correctionDB.insert(PersonalSchemaV3.JournalRecord(id: correctionRow.id, day: day.offset(-1), meal: .breakfast, data: try JSONEncoder().encode(correctionRow)))
    try correctionDB.save()
    let navigationStore = DiaryStore(container: container, catalog: Catalog(url: nil))
    try navigationStore.reload()
    let navigationRevision = navigationStore.pageRevision
    let navigationHistory = navigationStore.mealHistory
    let navigationStreak = navigationStore.streak
    let cachedBeforeSave = try navigationStore.presentationPage(for: day)
    check(cachedBeforeSave.items.isEmpty, "presentation starts with an empty day")
    navigationStore.select(day.offset(-1))
    check(navigationStore.items.contains { $0.id == correctionRow.id }, "navigation loads selected day")
    check(navigationStore.pageRevision == navigationRevision, "navigation does not republish diary data")
    check(navigationStore.mealHistory == navigationHistory && navigationStore.streak == navigationStreak,
          "navigation preserves history and streak")
    let laterRow = MealRow(food: "Синтетическая новая запись")
    correctionDB.insert(PersonalSchemaV3.JournalRecord(id: laterRow.id, day: day, meal: .lunch,
        data: try JSONEncoder().encode(laterRow)))
    try correctionDB.save()
    check(try navigationStore.presentationPage(for: day).items.isEmpty,
          "pager snapshot stays stable until a coordinated reload")
    navigationStore.select(day)
    check(navigationStore.items.contains { $0.id == laterRow.id }, "navigation observes another context's save")
    try navigationStore.reload()
    check(navigationStore.pageRevision == navigationRevision + 1, "reload invalidates page content")
    check(try navigationStore.presentationPage(for: day).items.contains { $0.id == laterRow.id },
          "reload publishes the new pager snapshot")
    // Compare the old navigation workload (full reload) with the new selected-page read.
    let fullStart = Date()
    for _ in 0..<50 { try navigationStore.reload() }
    let fullSeconds = Date().timeIntervalSince(fullStart)
    let selectStart = Date()
    for index in 0..<50 { navigationStore.select(day.offset(index % 2 == 0 ? 0 : -1)) }
    let selectSeconds = Date().timeIntervalSince(selectStart)
    print("Diary navigation Mac synthetic, 50 iterations: reload=\(fullSeconds)s select=\(selectSeconds)s; iOS widget work excluded")
    for record in try correctionDB.fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>()) where record.id == laterRow.id {
        correctionDB.delete(record)
    }
    try correctionDB.save()
    let correctionTime = calendar.date(bySettingHour: 9, minute: 15, second: 0, of: day.offset(-1).date)!
    let correction = MealTimeCorrection.Request(ids: [correctionRow.id], day: day.offset(-1).rawValue, meal: .breakfast, time: ISO8601DateFormatter().string(from: correctionTime))
    try MealTimeCorrection.apply(correction, container: container)
    try MealTimeCorrection.apply(correction, container: container)
    let correctedData = try ModelContext(container).fetch(FetchDescriptor<PersonalSchemaV3.JournalRecord>()).first!.data
    var correctedRow = try JSONDecoder().decode(MealRow.self, from: correctedData)
    check(correctedRow.timing?.consumedAt == correctionTime, "explicit time correction persists and is idempotent")
    correctedRow.timing = nil
    check(correctedRow == correctionRow, "time correction preserves food payload")
    let measurements = MeasurementRepository(container: container)
    var measurement = BodyMeasurement(kind: .weight, value: Decimal(string: "72.35")!, measuredAt: Date().addingTimeInterval(-3600))
    try measurements.save(measurement)
    measurement.value = Decimal(string: "72.45")!
    try measurements.save(measurement)
    let reopenedMeasurements = MeasurementRepository(container: try DiaryStore.makeContainer(url: directory.appendingPathComponent("test.store")))
    check(try reopenedMeasurements.all() == [measurement], "measurement exact decimal, UUID update, timestamp and disk reopen")
    var invalidMeasurement = measurement; invalidMeasurement.value = -1
    do { try measurements.save(invalidMeasurement); preconditionFailure("negative measurement") } catch {}
    check(try measurements.all() == [measurement], "invalid measurement preserves prior value")
    try measurements.delete(measurement.id)
    check(try measurements.all().isEmpty, "measurement delete persists")
    let entryID = UUID()
    var weightEntry = BodyMeasurement(kind: .weight, value: 73, measuredAt: Date().addingTimeInterval(-60))
    var waistEntry = BodyMeasurement(kind: .waist, value: 85, measuredAt: weightEntry.measuredAt)
    weightEntry.entryID = entryID; waistEntry.entryID = entryID
    try measurements.saveEntry([weightEntry, waistEntry])
    check(try measurements.all().count == 2, "two measurements in one entry")
    var badWaist = waistEntry; badWaist.value = -2
    var newWeight = weightEntry; newWeight.value = 75
    do { try measurements.saveEntry([newWeight, badWaist]); preconditionFailure("invalid group accepted") } catch {}
    check(try measurements.all().first(where: { $0.kind == .weight })?.value == 73, "invalid group cannot partially update weight")
    try measurements.save(BodyMeasurement(kind: .weight, value: 74, measuredAt: Date()))
    check(try measurements.all().filter { $0.kind == .waist }.count == 1, "weight-only input leaves old waist without fabricated measurement")
    let choiceStore = DiaryStore(container: try DiaryStore.makeContainer(memory: true), catalog: Catalog(url: nil))
    let choiceSession = MealSession(store: choiceStore, diagnosticLog: MatchingLog(directory: directory.appendingPathComponent("choice-logs")))
    await choiceSession.begin(day: day, meal: .dinner)
    await choiceSession.begin(day: day, meal: .snack)
    check(choiceSession.draft?.meal == .snack, "explicit snack replaces empty dinner draft")
    choiceSession.draft?.rows = [MealRow(food: "Яблоко")]
    let snackID = choiceSession.draft!.id
    await choiceSession.begin(day: day, meal: .dinner)
    check(choiceSession.draft?.meal == .dinner && choiceSession.draft?.id != snackID, "new dinner has its own draft")
    check(choiceSession.drafts.first { $0.id == snackID }?.meal == .snack, "nonempty snack remains available separately")
    try await choiceSession.flush()
    let firstSnackEpisode = UUID(), secondSnackEpisode = UUID()
    var snackA = MealRow(food: "Первый перекус")
    snackA.timing = MealTiming(episodeID: firstSnackEpisode, mode: .earlier, selectedAt: at(11), consumedAt: at(11))
    var snackB = MealRow(food: "Напиток первого перекуса")
    snackB.timing = MealTiming(episodeID: firstSnackEpisode, mode: .earlier, selectedAt: at(11), consumedAt: at(11))
    var snackC = MealRow(food: "Второй перекус")
    snackC.timing = MealTiming(episodeID: secondSnackEpisode, mode: .earlier, selectedAt: at(16), consumedAt: at(16))
    let snackCItem = DiaryItem(id: snackC.id, day: day, meal: .snack, row: snackC)
    let snackEpisodes = DiaryEpisode.snacks(in: [
        DiaryItem(id: snackA.id, day: day, meal: .snack, row: snackA),
        DiaryItem(id: snackB.id, day: day, meal: .snack, row: snackB),
        snackCItem])
    check(snackEpisodes.count == 2 && snackEpisodes[0].entries.count == 2 && snackEpisodes[1].entries == [snackCItem], "snacks are grouped and ordered by saved episode")
    check(DiaryEpisode.snacks(in: [DiaryItem(id: UUID(), day: day, meal: .snack, row: MealRow(food: "Старый 1")), DiaryItem(id: UUID(), day: day, meal: .snack, row: MealRow(food: "Старый 2"))]).count == 1, "legacy snacks are not split by guesswork")
    let reassignStore = DiaryStore(container: try DiaryStore.makeContainer(memory: true), catalog: Catalog(url: nil))
    let reassignRepository = MealRepository(container: reassignStore.container)
    let reassignEpisode = UUID()
    var reassignA = MealRow(food: "Молоко")
    reassignA.timing = MealTiming(episodeID: reassignEpisode, mode: .earlier, selectedAt: at(9), consumedAt: at(9))
    var reassignB = MealRow(food: "Хлопья")
    reassignB.timing = reassignA.timing
    try await reassignRepository.commit(MealDraft(timing: reassignA.timing, day: day, meal: .snack, rows: [reassignA, reassignB]))
    try await reassignRepository.reassignMeal([reassignA.id], to: .breakfast)
    var reassigned = try await reassignRepository.page(for: day)
    check(reassigned.items.count == 2 && reassigned.items.allSatisfy { $0.meal == .breakfast }, "changing one row moves the complete episode")
    check(reassigned.items.allSatisfy { $0.row.timing?.episodeID == reassignEpisode }, "meal reassignment preserves episode timing")
    await reassignRepository.injectSaveFailure()
    do { try await reassignRepository.reassignMeal([reassignA.id, reassignB.id], to: .dinner); preconditionFailure("expected reassignment rollback") } catch {}
    reassigned = try await reassignRepository.page(for: day)
    check(reassigned.items.allSatisfy { $0.meal == .breakfast }, "failed reassignment cannot partially move a meal")
    try await reassignRepository.reassignMeal([reassignA.id, reassignB.id], to: .breakfast)
    check(try await reassignRepository.page(for: day).items.allSatisfy { $0.meal == .breakfast }, "meal reassignment is idempotent")
    let repository = MealRepository(container: container)
    let product = Product(id: "synthetic-planner", name: "Тестовая еда", brand: "", basis: .g, calories: 200, protein: 10, fat: 4, carbs: 31, source: "synthetic")
    var first = MealRow(food: product.name, quantity: "200", unit: .g, product: product)
    first.addedAt = at(12)
    var draft = MealDraft(day: day, meal: .breakfast, rows: [first])
    draft.timing = MealTiming(startedAt: at(11))
    try await repository.commit(draft, now: at(13))
    var page = try await repository.page(for: day)
    check(page.items[0].row.timing?.consumedAt == at(13), "now records save time even when food was added earlier")
    check(page.items[0].row.timing?.source == "save-confirmation", "confirmed time records its source")
    let saved = page.items[0].row
    var edited = MealDraft(day: day, meal: .breakfast, rows: [saved])
    edited.editingEntryID = saved.id; edited.timing = saved.timing; edited.rows[0].quantity = "250"; edited.rows[0].snapshot = nil
    try await repository.commit(edited, now: at(20))
    page = try await repository.page(for: day)
    check(page.items[0].row.timing?.consumedAt == at(13), "weight edit does not move breakfast")
    page.goals = Nutrition(calories: 2450, protein: 170, fat: 70, carbs: 285)
    let initialGuidance = AdaptiveMealPlan.calculate(
        page: DiaryPageData(items: [], goals: page.goals), day: day, now: at(7))
    check(initialGuidance.suggestions.map(\.meal) == [.breakfast, .lunch, .dinner], "entry guidance uses all initial main meals")
    check(initialGuidance.suggestions.map { $0.nutrition.calories.map { Numbers.display($0, places: 0) } ?? "—" } == ["700", "887", "863"], "entry guidance matches visible calorie recommendations")
    let late = AdaptiveMealPlan.calculate(page: page, day: day, now: at(12))
    check(late.suggestions.first?.meal == .lunch && late.suggestions.first!.start >= at(15), "late breakfast moves lunch")
    check(late.suggestions.map(\.meal) == [.lunch, .dinner], "all remaining main meals stay visible")
    var snack = MealRow(food: "Яблоко", quantity: "100", unit: .g, product: product)
    snack.timing = MealTiming(mode: .earlier, selectedAt: at(14), consumedAt: at(14), source: "user")
    page.items.append(DiaryItem(id: snack.id, day: day, meal: .snack, row: snack))
    let withSnack = AdaptiveMealPlan.calculate(page: page, day: day, now: at(12))
    check(withSnack.suggestions.first?.start == late.suggestions.first?.start, "snack does not reset clock")
    check(withSnack.remaining.calories == late.remaining.calories! - 200, "snack reduces energy remainder")
    check(zip(withSnack.suggestions, late.suggestions).allSatisfy { after, before in
        guard let afterCalories = after.nutrition.calories, let beforeCalories = before.nutrition.calories else { return false }
        return after.meal == before.meal && afterCalories < beforeCalories
    }, "snack recalculates every remaining main meal")
    var unknown = MealRow(food: "Неизвестное блюдо")
    page.items.append(DiaryItem(id: unknown.id, day: day, meal: .snack, row: unknown))
    let incomplete = AdaptiveMealPlan.calculate(page: page, day: day, now: at(12))
    check(incomplete.remaining.calories == nil && incomplete.forecast.missingCalories > 0, "unknown is not zero")
    page.items.removeLast()
    var planned = MealDraft(day: day.offset(1), meal: .dinner, rows: [MealRow(food: product.name, quantity: "300", unit: .g, product: product)])
    planned.timing = MealTiming(mode: .planned, selectedAt: day.offset(1).date)
    try await repository.commit(planned, now: at(13))
    check(try await repository.page(for: day.offset(1)).total.calories == 0, "plan excluded from consumed calories")
    await repository.injectSaveFailure()
    do { try await repository.consumeEpisode(planned.timing!.episodeID, now: at(14)); preconditionFailure("expected rollback") } catch {}
    check(try await repository.page(for: day.offset(1)).items[0].row.timing?.isPlanned == true, "failed consume preserves plan")
    try await repository.consumeEpisode(planned.timing!.episodeID, now: at(14))
    try await repository.consumeEpisode(planned.timing!.episodeID, now: at(14))
    check(try await repository.page(for: day.offset(1)).items.isEmpty, "consumed plan moves to actual day")
    let consumed = try await repository.page(for: day)
    check(consumed.items.count == 2 && consumed.total.calories == 1100, "consume idempotent, no duplicate")
    do { try await repository.commit(planned, now: at(15)); preconditionFailure("stale plan cannot revert consumed") } catch {}
    check(try await repository.page(for: day).items.count == 2, "stale replay retains consumed episode")
    // Old payload is still decoded as consumed with unknown clock.
    unknown.snapshot = .unknown
    let oldData = try JSONEncoder().encode(unknown)
    check(try JSONDecoder().decode(MealRow.self, from: oldData).timing == nil, "legacy optional timing")
    var oldDraft = MealDraft(day: day.offset(-1), meal: .lunch, rows: [unknown])
    oldDraft.timing = MealTiming(startedAt: at(12))
    check(oldDraft.timing!.confirmed(rows: oldDraft.rows, day: oldDraft.day, now: at(14)).consumedAt == nil, "past day receives no invented current clock")
    let manuallyChosen = MealTiming(mode: .earlier, selectedAt: at(12))
    check(manuallyChosen.confirmed(rows: [first], day: day, now: at(15)).consumedAt == at(12), "manually chosen earlier time is preserved")
    var lunch = MealRow(food: product.name, quantity: "100", unit: .g, product: product)
    lunch.timing = MealTiming(mode: .earlier, selectedAt: at(14), consumedAt: at(14), source: "user")
    let breakfastAndLunch = DiaryPageData(items: [page.items[0], DiaryItem(id: lunch.id, day: day, meal: .lunch, row: lunch)], goals: page.goals)
    let afterDinnerWindow = AdaptiveMealPlan.calculate(page: breakfastAndLunch, day: day, now: at(21, 23))
    check(afterDinnerWindow.suggestions.map(\.meal) == [.dinner], "unfinished dinner remains visible after its window")
    check(afterDinnerWindow.suggestions[0].start == at(17) && afterDinnerWindow.suggestions[0].end == at(19), "missed dinner keeps the interval anchored to today's 14:00 lunch")
    let lateNight = AdaptiveMealPlan.calculate(page: breakfastAndLunch, day: day, now: at(23))
    check(lateNight.suggestions.map(\.meal) == [.dinner], "unfinished dinner remains visible through the day")
    // Observed meal times are deduplicated by day, never by number of ingredients.
    var history: [DiaryItem] = []
    for offset in 1...4 {
        let historicalDay = day.offset(-offset)
        let time = calendar.date(bySettingHour: 11, minute: offset * 5, second: 0, of: historicalDay.date)!
        var row = MealRow(food: "Тест", quantity: "100", unit: .g, product: product)
        row.timing = MealTiming(mode: .earlier, selectedAt: time, consumedAt: time, source: "user")
        let item = DiaryItem(id: row.id, day: historicalDay, meal: .breakfast, row: row)
        history.append(item)
        if offset == 1 { history += Array(repeating: item, count: 15) }
    }
    let rhythm = MealRhythm.learn(history, before: day)
    check(rhythm[.breakfast]?.days == 4 && rhythm[.breakfast]?.centerMinutes == 672.5, "history counts days and median, not ingredients")
    check(MealRhythm.learn(Array(history.prefix(2)), before: day).isEmpty, "one historical day does not establish rhythm")
    let emptyPage = DiaryPageData(items: [], goals: page.goals)
    let learned = AdaptiveMealPlan.calculate(page: emptyPage, day: day, now: at(7), history: history)
    check(learned.suggestions.first!.start > at(10) && learned.suggestions.first!.end.timeIntervalSince(learned.suggestions.first!.start) >= 7200, "learned flexible window spans at least two hours")
    let afterSleep = AdaptiveMealPlan.calculate(page: emptyPage, day: day, now: at(11), history: history, wakeTime: at(11))
    check(afterSleep.suggestions.first?.meal == .breakfast && afterSleep.suggestions.first!.start >= at(11), "late wake moves breakfast")
    let staleSleep = AdaptiveMealPlan.calculate(page: emptyPage, day: day, now: at(7), history: history, wakeTime: at(11).addingTimeInterval(-86400))
    check(staleSleep.suggestions.first!.start == learned.suggestions.first!.start, "stale sleep ignored")
    let mainSleep = DateInterval(start: at(7).addingTimeInterval(-8 * 3600), end: at(7))
    let nap = DateInterval(start: at(13), end: at(14))
    check(SleepWindow.wake(from: [mainSleep, mainSleep, nap], now: at(15)) == at(7), "duplicate sources and nap do not replace main sleep")
    check(SleepWindow.wake(from: [nap, nap, nap, nap], now: at(15)) == nil, "duplicates cannot turn nap into main sleep")
    check(SleepWindow.wake(from: [], now: at(15)) == nil, "no health records gives no invented wake")
    check(SleepWindow.wake(from: [DateInterval(start: at(7), end: at(20))], now: at(15)) == nil, "future-ended sleep ignored")
    let pastSleep = (1...5).map { offset -> DateInterval in
        let end = calendar.date(bySettingHour: 8, minute: offset * 5, second: 0, of: day.offset(-offset).date)!
        return DateInterval(start: end.addingTimeInterval(-8 * 3600), end: end)
    }
    let predicted = WakeEstimate.calculate(intervals: pastSleep, now: at(7))
    check(predicted?.observed == false && predicted?.days == 5 && calendar.component(.minute, from: predicted!.date) == 15, "missing today uses historical median with explicit provenance")
    let actualWake = at(10)
    let arrived = WakeEstimate.calculate(intervals: pastSleep + [DateInterval(start: actualWake.addingTimeInterval(-8 * 3600), end: actualWake)], now: at(12))
    check(arrived?.observed == true && arrived?.date == actualWake, "late sync replaces prediction with actual sleep")
    check(WakeEstimate.calculate(intervals: Array(pastSleep.prefix(2)), now: at(7)) == nil, "two days cannot manufacture prediction")
    let predictedPlan = AdaptiveMealPlan.calculate(page: emptyPage, day: day, now: at(7), wakeTime: predicted?.date)
    check(predictedPlan.suggestions.first!.start > at(8), "prediction may be later than current clock")
    let archive = HealthArchive(root: directory.appendingPathComponent("health"))
    check(try await archive.latest("sleep") == nil, "empty archive cursor")
    let deletion = UUID()
    let payload = HealthArchive.Batch(type: "sleep", receivedAt: Date(), anchor: Data([1,2]), samples: Data([3,4]), added: 1, deletedIDs: [deletion])
    try await archive.save(payload)
    let restored = try await HealthArchive(root: directory.appendingPathComponent("health")).latest("sleep")
    check(restored?.anchor == payload.anchor && restored?.samples == payload.samples && restored?.deletedIDs == [deletion], "archive atomically preserves cursor records and deletions across reopen")
    let beforeMidnight = calendar.date(bySettingHour: 23, minute: 50, second: 0, of: day.date)!
    let afterMidnight = calendar.date(bySettingHour: 0, minute: 10, second: 0, of: day.date)!
    check(HealthInsights.meanClock([beforeMidnight, afterMidnight], calendar: calendar) == "00:00", "bedtime average wraps midnight")
    check(HealthInsights.mean([nil, 1000, 3000]) == 2000 && HealthInsights.mean([nil, nil]) == nil, "missing day is not zero")
    check(HealthDay(date: at(7), steps: nil, activeEnergy: 500, restingEnergy: 1600).totalEnergy == 2100, "rest plus active energy")
    check(HealthDay(date: at(7), steps: nil, activeEnergy: 500, restingEnergy: nil).totalEnergy == nil, "partial energy cannot be full expenditure")
    let nights = HealthInsights.nights([mainSleep, mainSleep, nap], now: at(15))
    check(nights.count == 1 && nights[0].seconds == 8 * 3600, "sleep insight excludes duplicate intervals and short nap")
    print("PASS: planner time provenance, late breakfast, snack, incomplete values, plan/fact persistence, rollback and idempotency")
}
