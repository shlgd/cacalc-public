import Foundation
import AVFoundation
import Observation
import UIKit

/// Store relative filenames, so an app update/sandbox relocation cannot break recovery.
enum VoiceFiles {
    static var directory: URL {
        #if os(macOS)
        if let path = ProcessInfo.processInfo.environment["CACALC_TEST_CACHE_DIRECTORY"] {
            return URL(fileURLWithPath: path).appendingPathComponent("VoiceDrafts", isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceDrafts", isDirectory: true)
    }
    static func url(_ filename: String) -> URL { directory.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent) }
    static func create() throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var location = directory, values = URLResourceValues(); values.isExcludedFromBackup = true
        try location.setResourceValues(values)
        return UUID().uuidString + ".wav"
    }
    static func remove(_ filename: String?) {
        if let filename { try? FileManager.default.removeItem(at: url(filename)) }
    }
}

@MainActor @Observable final class VoiceSession: NSObject, @preconcurrency AVAudioRecorderDelegate {
    static let mealVoice = VoiceSession()
    enum Phase { case idle, requesting, downloading, recording, paused, transcribing, extracting }
    var phase = Phase.idle
    var returningMealControls = false
    var liveFinishing = false
    var ready = false
    var needsModels = false
    var warming = false
    var progress = 0.0
    var downloadName = ""
    var error: String?
    var mealPreview: String?
    var mealRecordingFinished = false
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var liveFile: String?
    @ObservationIgnored private var recordingMeal = false
    @ObservationIgnored private weak var recordingOwner: MealSession?
    var recordedSeconds: TimeInterval { recorder?.currentTime ?? 0 }
    func inputLevel() -> Double {
        guard phase == .recording, let recorder else { return 0 }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        // Match SuperDictate's voice-visibility mapping; this is not ASR gain.
        guard decibels.isFinite else { return 0 }
        let gated = (decibels + 52) / 20
        guard gated > 0.06 else { return 0 }
        return pow(min(1, max(0, gated)), 0.42)
    }
    @ObservationIgnored let assets: VoiceAssets
    @ObservationIgnored private var audioLease: UUID?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    private func beginOperation() -> UUID { operationID = UUID(); return operationID }
    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        phase = .idle; liveFinishing = false; operation = nil
    }
    @ObservationIgnored private let engine: VoiceEngine
    @ObservationIgnored private var warmup: Task<Void, Never>?
    override init() {
        let assets = VoiceAssets.shared
        self.assets = assets
        #if DEBUG
        engine = VoiceEngine(assets: assets, speechComputeUnits: UserDefaults.standard.bool(forKey: "speechCPUTrial") ? .cpuOnly : .cpuAndNeuralEngine)
        #else
        engine = VoiceEngine(assets: assets)
        #endif
        super.init()
    }
    private func warmSpeech() {
        guard !warming else { return }
        warming = true
        warmup = Task {
            let span = VoicePreparationTrace.Span("speech.background-warmup")
            var outcome = "cancelled"
            defer { warming = false; span.finish(outcome) }
            do {
                ready = try await assets.isReady(models: ["parakeet"])
                if ready { try await engine.prepareLiveSpeech(); outcome = "ready" }
                else { outcome = "assets-not-installed" }
            }
            catch is CancellationError {} catch {
                outcome = "error: " + error.localizedDescription
                self.error = "Не удалось подготовить распознавание. Аудиозапись сохранится. " + error.localizedDescription
            }
        }
    }

    // Capture the setting at session start: changing it cannot split a recording's lifecycle.
    static var animationTestingEnabled: Bool {
        UserDefaults.standard.object(forKey: "mealAnimationTesting") as? Bool ?? false
    }
    private var mealAnimationTesting = false
    func prepareMealSpeech() {
        #if DEBUG
        if VoiceStartupProbe.enabled { return }
        #endif
        if !Self.animationTestingEnabled { warmSpeech() }
    }
    func waitForSpeechPreparation() async { await warmup?.value }
    var processing: Bool { phase == .transcribing || phase == .extracting || phase == .downloading }
    var capturing: Bool { phase == .recording || phase == .paused }
    var locked: Bool { liveFinishing || processing || capturing || phase == .requesting || returningMealControls }
    func prepare(_ library: ProductLibrary) {
        guard !locked else { return }
        let id = beginOperation()
        phase = .downloading; error = nil
        operation = Task {
            defer { finishOperation(id) }
            do {
                try await assets.prepare(models: ["parakeet"]) { [weak self] value, name in
                    Task { @MainActor in guard let self, self.operationID == id else { return }; self.progress = value; self.downloadName = name }
                }
                guard operationID == id, !Task.isCancelled else { return }
                ready = true
                needsModels = false
                try await processRecording(library)
            } catch is CancellationError {} catch {
                if operationID == id, !Task.isCancelled { self.error = "Загрузка прервана. Готовые файлы сохранены. " + error.localizedDescription }
            }
        }
    }
    func start(_ library: ProductLibrary) async {
        // Recording must not wait for model checks, downloads or ASR preparation.
        guard !locked, let requested = library.beginOperation() else { return }
        let id = beginOperation()
        error = nil; phase = .requesting
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard operationID == id, phase == .requesting, library.showingEditor, library.owns(requested) else {
            if operationID == id { phase = .idle }; return
        }
        guard allowed else {
            phase = .idle
            error = "Нет доступа к микрофону. Разрешите его в настройках iPhone или заполните поля вручную."
            return
        }
        let oldFile = library.draft?.audioFile
        let oldTranscript = library.draft?.transcript ?? ""
        let oldStage = library.draft?.voiceStage
        let lease = UUID()
        audioLease = lease
        var newFile: String?
        do {
            let file = try VoiceFiles.create(); newFile = file
            library.draft?.audioFile = file
            library.draft?.transcript = ""
            library.draft?.voiceStage = .recorded
            library.changed()
            guard let recording = library.draft else { throw CancellationError() }
            try await library.flush()
            guard phase == .requesting, library.showingEditor, library.owns(recording) else { throw CancellationError() }
            try await VoiceAudioSession.shared.activate(lease)
            guard audioLease == lease, phase == .requesting, library.showingEditor,
                  library.owns(recording), library.draft?.audioFile == file else { throw CancellationError() }
            let recorder = try await VoiceAudioSession.shared.startRecorder(at: VoiceFiles.url(file), lease: lease)
            guard audioLease == lease, phase == .requesting, library.showingEditor,
                  library.owns(recording), library.draft?.audioFile == file else {
                recorder.stop()
                throw CancellationError()
            }
            self.recorder = recorder; recorder.delegate = self
            recordingMeal = false; recordingOwner = nil
            phase = .recording
            warmSpeech()
            if let oldFile, try await !library.repository.audioIsReferenced(oldFile) { VoiceFiles.remove(oldFile) }
        } catch {
            let ownsAttempt = audioLease == lease
            if ownsAttempt {
                phase = .idle
                recorder?.stop(); recorder = nil; deactivate()
            } else {
                await VoiceAudioSession.shared.deactivate(lease)
            }
            if library.draft?.audioFile == newFile {
                library.draft?.audioFile = oldFile
                library.draft?.transcript = oldTranscript
                library.draft?.voiceStage = oldStage
                library.changed()
            }
            VoiceFiles.remove(newFile)
            if ownsAttempt && !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    func pause() {
        if phase == .recording { recorder?.pause(); phase = .paused }
        else if phase == .paused {
            if recorder?.record() == true { phase = .recording }
            else { error = "Не удалось продолжить запись. Сохранённое аудио можно обработать повторно."; stop() }
        }
    }
    func stop(reason: String = "session-stop") {
        guard capturing else { return }
        recordingOwner?.log("recordingStopped", fields: ["seconds": String(recordedSeconds), "phase": String(describing: phase), "reason": reason])
        if self === Self.mealVoice { MealRecordingActivity.shared.end() }
        phase = .idle
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        deactivate()
    }
    private func deactivate() {
        guard let lease = audioLease else { return }
        audioLease = nil
        Task { await VoiceAudioSession.shared.deactivate(lease) }
    }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard self.recorder === recorder else { return }
        recordingOwner?.log("recordingEndedBySystem", fields: ["success": String(flag), "seconds": String(recorder.currentTime)])
        if self === Self.mealVoice { MealRecordingActivity.shared.end() }
        self.recorder = nil; phase = .idle; deactivate()
        if flag && recordingMeal { mealRecordingFinished = true }
        if !flag { error = "Запись прервалась. Попробуйте обработать сохранённое аудио или повторить диктовку." }
    }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        guard self.recorder === recorder else { return }
        stop(); self.error = "Ошибка записи. " + (error?.localizedDescription ?? "Попробуйте ещё раз.")
    }
    func transcribe(_ library: ProductLibrary) {
        stop()
        guard !locked, library.draft != nil else { return }
        let id = beginOperation()
        phase = .transcribing; error = nil
        operation = Task {
            defer { finishOperation(id) }
            do {
                try await library.flush()
                try await processRecording(library)
            } catch is CancellationError {} catch { if operationID == id { self.error = error.localizedDescription } }
        }
    }
    private func processRecording(_ library: ProductLibrary) async throws {
        try Task.checkCancellation()
        let id = operationID
        guard let original = library.beginOperation() else { return }
        if library.draft?.voiceStage != .transcribed {
            ready = try await assets.isReady(models: ["parakeet"])
            guard operationID == id, !Task.isCancelled else { return }
            guard ready else { needsModels = true; return }
            guard library.owns(original), let filename = original.audioFile else { return }
            phase = .transcribing
            await warmup?.value
            try Task.checkCancellation()
            let start = ContinuousClock.now
            let text = try await engine.transcribe(VoiceFiles.url(filename))
            print("CACALC_ASR_DURATION: \(start.duration(to: .now))")
            try Task.checkCancellation()
            guard library.owns(original) else { return }
            library.draft?.transcript = text
            library.draft?.voiceStage = .transcribed
            library.changed()
            try await library.flush()
        }
        guard operationID == id, !Task.isCancelled else { return }
        phase = .extracting
        try await applyLabelFields(library)
    }
    private func applyLabelFields(_ library: ProductLibrary) async throws {
        guard let original = library.draft else { return }
        let start = ContinuousClock.now
        let result = try await Task.detached(priority: .userInitiated) {
            try RussianLabelParser.parse(original.transcript)
        }.value
        print("CACALC_LABEL_PARSE_DURATION: \(start.duration(to: .now))")
        try Task.checkCancellation()
        guard library.owns(original) else { return }
        library.draft = result.applying(to: original)
        library.draft?.voiceStage = .applied
        library.changed()
        try await library.flush()
    }
    func cancel() {
        operation?.cancel(); liveTask?.cancel()
        operation = nil; operationID = UUID()
        if !capturing { phase = .idle; liveFinishing = false; deactivate() }
    }
    func cancelMealRecording(_ meal: MealSession) {
        guard capturing, recordingMeal else { return }
        liveTask?.cancel(); liveTask = nil; liveFile = nil
        recordingMeal = false
        mealRecordingFinished = false
        // Detach the recorder delegate before stopping, so cancellation cannot trigger ASR.
        stop()
        error = nil; mealPreview = nil
        if let id = meal.draft?.id, let file = meal.draft?.audioFile {
            meal.discardRecording(draftID: id, file: file)
        }
    }
    func startMeal(_ meal: MealSession) async {
        guard !locked, !meal.busy, let original = meal.draft else { return }
        guard !meal.hasPendingDictation else {
            error = "Сначала повторите обработку предыдущей диктовки или удалите черновик."; return
        }
        let id = beginOperation()
        mealAnimationTesting = Self.animationTestingEnabled
        error = nil; mealPreview = nil; mealRecordingFinished = false; recordingMeal = true; phase = .requesting
        let allowed: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: allowed = true
        case .denied: allowed = false
        default: allowed = await AVAudioApplication.requestRecordPermission()
        }
        guard operationID == id, phase == .requesting, meal.showing, meal.draft?.id == original.id else { return }
        guard allowed else {
            phase = .idle; error = "Разрешите микрофон в настройках iPhone или добавьте еду через поиск."; return
        }
        let lease = UUID()
        audioLease = lease
        var newFile: String?
        do {
            try await meal.prepareArchive()
            guard operationID == id, audioLease == lease, phase == .requesting,
                  meal.showing, meal.draft?.id == original.id else { throw CancellationError() }
            let file = try VoiceFiles.create(); newFile = file
            meal.draft?.dictationID = UUID(uuidString: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent)
            meal.draft?.audioFile = file; meal.draft?.transcript = ""; meal.draft?.appliedTranscript = nil
            meal.draft?.dictationPreviewOnly = true
            meal.draft?.liveMode = true
            meal.draft?.liveAudioSampleOffset = 0
            meal.draft?.livePendingText = nil
            meal.draft?.liveSemanticRows = nil
            meal.liveOperation(file: file, renew: true)
            guard phase == .requesting, meal.showing, meal.draft?.id == original.id else { throw CancellationError() }
            MealAnimationProbe.shared.mark("session begin")
            try await VoiceAudioSession.shared.activate(lease)
            MealAnimationProbe.shared.mark("session end")
            guard audioLease == lease, phase == .requesting, meal.showing,
                  meal.draft?.id == original.id else { throw CancellationError() }
            MealAnimationProbe.shared.mark("record begin")
            let recorder = try await VoiceAudioSession.shared.startRecorder(at: VoiceFiles.url(file), lease: lease)
            MealAnimationProbe.shared.mark("record end")
            guard audioLease == lease, phase == .requesting, meal.showing,
                  meal.draft?.id == original.id else {
                recorder.stop()
                throw CancellationError()
            }
            self.recorder = recorder; recorder.delegate = self
            phase = .recording
            recordingOwner = meal
            meal.log("recordingStarted", fields: ["audioSessionMode": AVAudioSession.sharedInstance().mode.rawValue, "audioInputPorts": AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ","), "audioInputGain": String(AVAudioSession.sharedInstance().inputGain), "audioFile": file, "asr": "parakeet-tdt-0.6b-v3", "asrLanguage": "auto", "voiceManifest": Bundle.main.url(forResource: "voice-models", withExtension: "json").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "unavailable"])
            MealRecordingActivity.shared.start(meal: meal, recordingID: lease)
            meal.draft?.pendingResponse = nil
            meal.draft?.lastRequestSeconds = nil
            meal.draft?.inputTokens = nil; meal.draft?.outputTokens = nil
            // Persistence and Core ML preparation cannot delay opening the microphone.
            meal.changed()
            if mealAnimationTesting {
                meal.liveProgress = .init(title: "Записываю аудио · тест анимации")
                meal.log("animationTestRecording", fields: ["recognition": "disabled", "audio": "archived-on-finish"])
            } else {
                warmSpeech()
                beginLive(meal, file: file, owner: original.id)
            }
            Task {
                do {
                    try await meal.flush()
                    if meal.draft?.id == original.id, meal.draft?.audioFile == file {
                        if let old = original.audioFile, try await !meal.repository.audioIsReferenced(old) { VoiceFiles.remove(old) }
                    }
                } catch {
                    guard meal.draft?.id == original.id else { return }
                    meal.error = "Аудио записывается, но черновик пока не сохранён. " + error.localizedDescription
                }
            }
        } catch {
            let ownsAttempt = audioLease == lease
            if ownsAttempt {
                recorder?.stop(); recorder = nil; phase = .idle; deactivate()
            } else {
                await VoiceAudioSession.shared.deactivate(lease)
            }
            if meal.draft?.id == original.id, meal.draft?.audioFile == newFile {
                meal.draft?.dictationID = original.dictationID
                meal.draft?.audioFile = original.audioFile; meal.draft?.transcript = original.transcript
                meal.draft?.appliedTranscript = original.appliedTranscript
                meal.draft?.dictationPreviewOnly = original.dictationPreviewOnly
                meal.draft?.liveMode = original.liveMode
                meal.draft?.liveAudioSampleOffset = original.liveAudioSampleOffset
                meal.draft?.livePendingText = original.livePendingText
                meal.draft?.liveSemanticRows = original.liveSemanticRows
                meal.changed()
            }
            VoiceFiles.remove(newFile)
            if ownsAttempt && !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    func prepareMeal(_ meal: MealSession) {
        guard !locked else { return }
        let id = beginOperation()
        phase = .downloading; error = nil
        operation = Task {
            defer { finishOperation(id) }
            do {
                try await assets.prepare(models: ["parakeet"]) { [weak self] value, name in
                    Task { @MainActor in guard let self, self.operationID == id else { return }; self.progress = value; self.downloadName = name }
                }
                guard operationID == id, !Task.isCancelled else { return }
                ready = true; needsModels = false
                try await processMealRecording(meal)
            } catch is CancellationError {} catch { if operationID == id { self.error = error.localizedDescription } }
        }
    }
    func transcribeMeal(_ meal: MealSession) {
        guard !liveFinishing, !meal.busy, capturing || !locked else { return }
        let id = beginOperation()
        let live = meal.draft?.liveMode == true
        if capturing {
            recordingOwner?.log("recordingStopped", fields: ["seconds": String(recordedSeconds), "phase": String(describing: phase), "reason": "finish-recording"])
            MealRecordingActivity.shared.end()
        }
        let endingRecorder = recorder
        recorder = nil
        endingRecorder?.delegate = nil
        let endingLease = audioLease
        audioLease = nil
        liveFinishing = true
        phase = live ? .idle : .transcribing
        error = nil
        operation = Task {
            defer { finishOperation(id) }
            if let endingRecorder { await VoiceAudioSession.shared.finishRecorder(endingRecorder) }
            if let endingLease { await VoiceAudioSession.shared.deactivate(endingLease) }
            guard operationID == id, !Task.isCancelled else { return }
            do { try await processMealRecording(meal) }
            catch is CancellationError {} catch { if operationID == id { self.error = error.localizedDescription } }
        }
    }
    private func beginLive(_ meal: MealSession, file: String, owner: UUID) {
        liveTask?.cancel()
        liveFile = file
        meal.liveProgress = .init(title: "Готовлю распознавание", working: true)
        liveTask = Task {
            do { try await runLive(meal, file: file, owner: owner) }
            catch is CancellationError {} catch {
                guard meal.draft?.id == owner, meal.draft?.audioFile == file else { return }
                meal.liveProgress = nil
                meal.log("liveFailed", fields: ["error": error.localizedDescription])
                self.error = "Живой разбор прерван. Аудио сохранено для повтора. " + error.localizedDescription
            }
        }
    }
    private func stopLiveCommand(_ meal: MealSession, file: String) async throws {
        MealRecordingActivity.shared.end()
        let endingRecorder = recorder
        recorder = nil
        endingRecorder?.delegate = nil
        let endingLease = audioLease
        audioLease = nil
        liveFinishing = true
        phase = .idle
        defer { liveFinishing = false }
        if let endingRecorder { await VoiceAudioSession.shared.finishRecorder(endingRecorder) }
        if let endingLease { await VoiceAudioSession.shared.deactivate(endingLease) }
        meal.log("recordingStopped", fields: ["reason": "voice-command"])
        try await meal.finishLive(file: file)
        mealPreview = nil
    }
    private func runLive(_ meal: MealSession, file: String, owner: UUID) async throws {
        let preparing = Date()
        meal.log("livePreparationStarted", fields: ["draftID": owner.uuidString,
            "endpointPolicy": "quiet-or-stop-v2", "forcedSpeechCut": "false"])
        await warmup?.value
        try Task.checkCancellation()
        guard try await assets.isReady(models: ["parakeet"]) else {
            needsModels = true
            throw FoodError.database("Сначала загрузите модель распознавания.")
        }
        try await engine.prepareSpeech()
        try Task.checkCancellation()
        guard meal.draft?.id == owner, meal.draft?.audioFile == file else { return }
        meal.log("livePreparationReady", fields: ["seconds": String(Date().timeIntervalSince(preparing))])
        meal.showLiveText(meal.draft?.livePendingText ?? "")
        var baseSample = meal.draft?.liveAudioSampleOffset ?? 0
        var audio = LiveAudioBuffer(from: baseSample)
        var endpoint = LiveMealEndpoint()
        var reportedTransientCount = 0
        var commandProbeThrough = -1
        var cadence = LivePreviewCadence()
        var previewFinishedAt = Date.distantPast
        var asrCalls = 0, asrSamples = 0
        defer {
            meal.log("liveWorkSummary", fields: ["draftID": owner.uuidString,
                "audioSamplesRead": String(audio.samplesRead), "audioReadCalls": String(audio.reads),
                "peakBufferedSamples": String(audio.peakSamples), "asrCalls": String(asrCalls),
                "asrSamples": String(asrSamples), "previewPolicy": "growing-step-v1"])
        }
        while true {
            try Task.checkCancellation()
            guard meal.draft?.id == owner, meal.draft?.audioFile == file else { return }
            // Capture may continue under Live Activity. Inference resumes in foreground.
            if UIApplication.shared.applicationState != .active {
                try await Task.sleep(for: .milliseconds(500)); continue
            }
            let finished = !capturing || liveFile != file
            guard let request = meal.liveOperation(file: file) else { return }
            let readOffset = audio.readOffset
            let window = try await Task.detached {
                try LiveWave.read(VoiceFiles.url(file), from: readOffset, finalized: finished)
            }.value
            guard meal.ownsLive(request, file: file) else { return }
            audio.append(window.samples)
            let samples = audio.samples
            let atEnd = audio.readOffset >= window.totalSamples
            let nextRange = endpoint.next(samples, finished: finished && atEnd)
            if endpoint.rejectedTransientCount > reportedTransientCount {
                meal.log("audioTransientRejected", fields: ["count": String(endpoint.rejectedTransientCount - reportedTransientCount),
                    "minimumActiveMilliseconds": "60", "rmsThreshold": "0.008", "throughSample": String(baseSample + endpoint.cursor)])
                reportedTransientCount = endpoint.rejectedTransientCount
            }
            if nextRange == nil, !finished, let range = endpoint.commandRange,
               baseSample + range.upperBound != commandProbeThrough {
                commandProbeThrough = baseSample + range.upperBound
                let started = Date()
                meal.log("liveASRInput", fields: ["fromSample": String(baseSample + range.lowerBound),
                    "throughSample": String(baseSample + range.upperBound),
                    "paddingSamples": String(max(0, 4_800 - range.count))])
                asrCalls += 1; asrSamples += range.count
                let text = try await engine.transcribeLive(Array(samples[range]))
                try Task.checkCancellation()
                guard meal.ownsLive(request, file: file) else { return }
                let recognized = MealVoiceCommand.isStandalone(text)
                meal.log("voiceCommandProbe", fields: ["text": text, "recognized": String(recognized),
                    "throughSample": String(commandProbeThrough), "quietMilliseconds": "250",
                    "seconds": String(Date().timeIntervalSince(started))])
                if recognized {
                    let stop = try await meal.acceptLivePhrase(text, through: commandProbeThrough,
                        owner: owner, file: file, boundary: true, operation: request)
                    baseSample += range.upperBound
                    audio.discard(through: baseSample); cadence = LivePreviewCadence()
                    endpoint = LiveMealEndpoint()
                    reportedTransientCount = 0
                    mealPreview = nil
                    if stop {
                        try await stopLiveCommand(meal, file: file)
                        return
                    }
                    continue
                }
            }
            if let range = nextRange {
                let started = Date()
                if meal.liveProgress == nil { meal.liveProgress = .init(title: "Распознаю фразу", working: true) }
                else { meal.liveProgress?.title = "Распознаю фразу"; meal.liveProgress?.working = true }
                meal.log("liveASRStarted", fields: ["fromSample": String(baseSample + range.lowerBound), "throughSample": String(baseSample + range.upperBound)])
                meal.log("liveASRInput", fields: ["fromSample": String(baseSample + range.lowerBound),
                    "throughSample": String(baseSample + range.upperBound),
                    "paddingSamples": String(max(0, 4_800 - range.count))])
                asrCalls += 1; asrSamples += range.count
                let text = try await engine.transcribeLive(Array(samples[range]))
                try Task.checkCancellation()
                guard meal.ownsLive(request, file: file) else { return }
                meal.log("transcriptionResult", fields: ["mode": "live-local", "text": text,
                    "fromSample": String(baseSample + range.lowerBound), "throughSample": String(baseSample + range.upperBound),
                    "seconds": String(Date().timeIntervalSince(started))])
                let stopRequested = try await meal.acceptLivePhrase(text, through: baseSample + range.upperBound, owner: owner, file: file,
                    boundary: true, operation: request)
                if stopRequested {
                    try await stopLiveCommand(meal, file: file)
                    return
                }
                mealPreview = meal.draft?.livePendingText
                baseSample += range.upperBound
                audio.discard(through: baseSample); cadence = LivePreviewCadence()
                endpoint = LiveMealEndpoint()
                reportedTransientCount = 0
                continue
            }
            if finished && atEnd {
                // Flush an incomplete phrase retained across a natural pause.
                try await meal.acceptLivePhrase("", through: window.totalSamples + 1, owner: owner, file: file, boundary: true, operation: request)
                try await meal.finishLive(file: file)
                mealPreview = nil
                return
            }
            if !finished, atEnd, let range = endpoint.previewRange,
               cadence.ready(samples: range.count),
               Date().timeIntervalSince(previewFinishedAt) >= 0.8 {
                let started = Date()
                meal.log("liveASRInput", fields: ["fromSample": String(baseSample + range.lowerBound),
                    "throughSample": String(baseSample + range.upperBound),
                    "paddingSamples": String(max(0, 4_800 - range.count))])
                asrCalls += 1; asrSamples += range.count
                let text = try await engine.transcribeLive(Array(samples[range]))
                try Task.checkCancellation()
                guard meal.ownsLive(request, file: file) else { return }
                cadence.completed(samples: range.count)
                previewFinishedAt = Date()
                meal.log("liveASRHypothesis", fields: ["text": text,
                    "fromSample": String(baseSample + range.lowerBound),
                    "throughSample": String(baseSample + range.upperBound),
                    "seconds": String(previewFinishedAt.timeIntervalSince(started))])
                if capturing {
                    try await meal.acceptLiveHypothesis(text, owner: owner, file: file, operation: request)
                }
            }
            let discard = endpoint.discardableSamples
            baseSample += discard
            audio.discard(through: baseSample)
            endpoint.discardPrefix(discard)
            if atEnd { try await Task.sleep(for: .milliseconds(300)) }
        }
    }
    private func processMealRecording(_ meal: MealSession) async throws {
        let generation = operationID, owner = meal.draft?.id
        if mealAnimationTesting, meal.draft?.liveMode == true, let file = meal.draft?.audioFile {
            meal.log("animationTestFinished", fields: ["recognition": "disabled"])
            try await meal.finishLive(file: file)
            return
        }
        if meal.draft?.liveMode == true {
            await liveTask?.value
            guard operationID == generation, meal.draft?.id == owner, !Task.isCancelled else { throw CancellationError() }
            liveTask = nil
            if let draft = meal.draft, let file = draft.audioFile {
                try await runLive(meal, file: file, owner: draft.id)
            }
            liveFile = nil
            return
        }
        try await processLegacyMealRecording(meal)
    }
    // Retained for older saved drafts and rollback; new dictations never call Luna.
    private func processLegacyMealRecording(_ meal: MealSession) async throws {
        let generation = operationID
        guard let original = meal.draft, let file = original.audioFile else { return }
        try await meal.flush()
        try await meal.preserveAudio(file, owner: original)
        ready = try await assets.isReady(models: ["parakeet"])
        guard operationID == generation, !Task.isCancelled else { return }
        guard ready else { needsModels = true; return }
        phase = .transcribing
        await warmup?.value
        try Task.checkCancellation()
        let started = Date()
        meal.log("transcriptionStarted", fields: ["draftID": original.id.uuidString, "dictationID": original.dictationID?.uuidString ?? ""])
        let text: String
        do { text = try await engine.transcribe(VoiceFiles.url(file), retainingModels: true) }
        catch {
            meal.log("transcriptionFailed", fields: ["draftID": original.id.uuidString, "dictationID": original.dictationID?.uuidString ?? "", "error": error.localizedDescription])
            try await meal.flushLog()
            throw error
        }
        meal.log("transcriptionResult", fields: ["draftID": original.id.uuidString, "dictationID": original.dictationID?.uuidString ?? "", "text": text, "seconds": String(Date().timeIntervalSince(started))])
        try await meal.flushLog()
        try Task.checkCancellation()
        guard meal.owns(original), meal.draft?.audioFile == file else { return }
        // Persist the transcript before discarding audio or starting the network request.
        meal.draft?.transcript = text
        meal.draft?.appliedTranscript = nil
        meal.draft?.dictationPreviewOnly = false
        meal.changed()
        let transcribed = meal.draft!
        try await meal.flush()
        guard meal.owns(transcribed), meal.draft?.audioFile == file else { return }
        meal.draft?.audioFile = nil
        meal.changed()
        try await meal.flush()
        if try await !meal.repository.audioIsReferenced(file) { VoiceFiles.remove(file) }
        try Task.checkCancellation()
        // ASR is complete. Let the existing 180 ms reverse animation restore controls
        // before starting the server stage. This wait never delays audio capture.
        let completed = meal.draft!
        returningMealControls = true
        phase = .idle
        defer { if operationID == generation { returningMealControls = false } }
        try await Task.sleep(for: .milliseconds(180))
        guard meal.showing, meal.owns(completed) else { return }
        meal.parse()
    }
    func enterMealBackground() {
        if liveFile != nil {
            if !MealRecordingActivity.shared.canRecordInBackground { stop(reason: "background-without-activity") }
            return
        }
        if !MealRecordingActivity.shared.canRecordInBackground { background() }
        // The meal session keeps its prepared Core ML models across screen/background
        // transitions. Recording permissions do not require discarding model memory.
    }
    func background() {
        if liveFile != nil { stop(reason: "editor-disappeared"); return }
        if phase == .requesting { phase = .idle; deactivate() }
        if self !== Self.mealVoice {
            warmup?.cancel()
            Task { await engine.releaseSpeech() }
        }
        // Metal inference is foreground-only. Retain audio/text and allow an explicit retry.
        stop()
        if processing { cancel() }
    }
}
