import ActivityKit
import UIKit

/// Owns a recording independently of the editor's lifetime. Intents execute in the app.
@MainActor final class MealRecordingActivity {
    static let shared = MealRecordingActivity()
    private var activity: Activity<RecordingActivityAttributes>?
    private var meal: MealSession?
    private var draftID: UUID?
    private var audioFile: String?
    private var observation: Task<Void, Never>?

    var canRecordInBackground: Bool {
        activity?.activityState == .active && VoiceSession.mealVoice.capturing
    }
    func start(meal: MealSession, recordingID: UUID) {
        guard let draft = meal.draft, let file = draft.audioFile else { return }
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            VoiceSession.mealVoice.error = "Live Activities выключены. Запись доступна только в открытом приложении."
            return
        }
        do {
            let now = Date()
            let attributes = RecordingActivityAttributes(recordingID: recordingID.uuidString, startedAt: now)
            let created = try Activity.request(attributes: attributes,
                content: ActivityContent(state: .init(status: "recording"), staleDate: nil),
                pushType: nil)
            self.activity = created; self.meal = meal; draftID = draft.id; audioFile = file
            observation = Task { [weak self] in
                for await state in created.activityStateUpdates {
                    guard let self, !Task.isCancelled,
                          self.activity?.id == created.id else { return }
                    if state == .dismissed || state == .ended {
                        // Removing the indicator stops capture but preserves audio for review.
                        try? await self.finish(recordingID: attributes.recordingID)
                        return
                    }
                }
            }
        } catch {
            VoiceSession.mealVoice.error = "Не удалось показать запись в Dynamic Island. Не сворачивайте приложение: " + error.localizedDescription
        }
    }
    private func ownedMeal(_ id: String) -> MealSession? {
        guard activity?.attributes.recordingID == id, let meal,
              meal.draft?.id == draftID, meal.draft?.audioFile == audioFile,
              VoiceSession.mealVoice.capturing else { return nil }
        return meal
    }
    func finish(recordingID: String) async throws {
        guard let meal = ownedMeal(recordingID) else { await removeStale(recordingID); return }
        let voice = VoiceSession.mealVoice
        let originalID = meal.draft?.id, originalFile = meal.draft?.audioFile
        let ending = end()
        voice.stop(reason: "live-activity-finished")
        await ending?.value
        meal.changed()
        do { try await meal.flush() }
        catch { meal.error = "Запись остановлена, но сохранение не завершилось: " + error.localizedDescription; throw error }
        guard meal.draft?.id == originalID, meal.draft?.audioFile == originalFile, !voice.capturing else { return }
        voice.mealRecordingFinished = true
        if UIApplication.shared.applicationState == .active, meal.showing {
            voice.mealRecordingFinished = false
            voice.transcribeMeal(meal)
        }
    }
    func cancel(recordingID: String) async throws {
        guard let meal = ownedMeal(recordingID) else { await removeStale(recordingID); return }
        let file = audioFile
        let ending = end()
        VoiceSession.mealVoice.cancelMealRecording(meal)
        await ending?.value
        // Await durable cancellation before the intent releases its background execution.
        do { try await meal.flush(); VoiceFiles.remove(file) }
        catch { meal.error = "Отмена записи пока не сохранена: " + error.localizedDescription; throw error }
    }
    @discardableResult func end() -> Task<Void, Never>? {
        let previousID = activity?.id
        activity = nil; meal = nil; draftID = nil; audioFile = nil
        observation?.cancel(); observation = nil
        guard let previousID else { return nil }
        return Task {
            for previous in Activity<RecordingActivityAttributes>.activities where previous.id == previousID {
                await previous.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
    func removeStale(_ recordingID: String? = nil) async {
        for existing in Activity<RecordingActivityAttributes>.activities {
            guard existing.id != activity?.id,
                  recordingID == nil || existing.attributes.recordingID == recordingID else { continue }
            await existing.end(nil, dismissalPolicy: .immediate)
        }
    }
}
