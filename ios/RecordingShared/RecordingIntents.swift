import AppIntents

struct FinishMealRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Завершить диктовку еды"
    static let openAppWhenRun: Bool = true
    @Parameter(title: "Запись") var recordingID: String
    init() {}
    init(recordingID: String) { self.recordingID = recordingID }
    @MainActor func perform() async throws -> some IntentResult {
        #if !RECORDING_WIDGET
        try await MealRecordingActivity.shared.finish(recordingID: recordingID)
        #endif
        return .result()
    }
}

struct CancelMealRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Отменить диктовку еды"
    static let openAppWhenRun: Bool = false
    @Parameter(title: "Запись") var recordingID: String
    init() {}
    init(recordingID: String) { self.recordingID = recordingID }
    @MainActor func perform() async throws -> some IntentResult {
        #if !RECORDING_WIDGET
        try await MealRecordingActivity.shared.cancel(recordingID: recordingID)
        #endif
        return .result()
    }
}
