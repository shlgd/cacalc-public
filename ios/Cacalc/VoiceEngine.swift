import Foundation
import CoreML
import FluidAudio
#if !targetEnvironment(simulator)
import MLX
import MLXLLM
import MLXLMCommon
#endif

/// Local-only loaders deliberately bypass SDK download helpers and mutable model branches.
actor VoiceEngine {
    let assets: VoiceAssets
    private let languageModelDirectory: URL?
    private let speechComputeUnits: MLComputeUnits
    private var speechModels: AsrModels?
    private var liveManager: AsrManager?
    private var livePreparation: Task<Void, Error>?
    private var tracedFirstInference = false
    init(assets: VoiceAssets, languageModelDirectory: URL? = nil, speechComputeUnits: MLComputeUnits = .cpuAndNeuralEngine) {
        self.assets = assets; self.languageModelDirectory = languageModelDirectory
        self.speechComputeUnits = speechComputeUnits
    }
    func prepareSpeech() async throws {
        try Task.checkCancellation()
        guard speechModels == nil else { return }
        let loadStart = ContinuousClock.now
        let directory = try await assets.directory("parakeet")
        guard speechModels == nil else { return }
        let config = MLModelConfiguration(); config.computeUnits = speechComputeUnits
        let cpu = MLModelConfiguration(); cpu.computeUnits = .cpuOnly
        func load(_ name: String, _ configuration: MLModelConfiguration) throws -> MLModel {
            try Task.checkCancellation()
            let started = ContinuousClock.now
            let model = try VoicePreparationTrace.measure("coreml." + name) {
                try MLModel(contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: configuration)
            }
            print("CACALC_ASR_COMPONENT: name=\(name) duration=\(started.duration(to: .now))")
            return model
        }
        let vocabulary = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json")))
        let models = AsrModels(encoder: try load("Encoder", config),
                               preprocessor: try load("Preprocessor", cpu),
                               decoder: try load("Decoder", config),
                               joint: try load("JointDecisionv3", config), configuration: config,
                               vocabulary: Dictionary(uniqueKeysWithValues: vocabulary.compactMap { key, value in
                                   Int(key).map { ($0, value) }
                               }), version: .v3)
        try Task.checkCancellation()
        speechModels = models
        print("CACALC_ASR_LOAD: \(loadStart.duration(to: .now))")
    }
    func releaseSpeech() async {
        livePreparation?.cancel()
        _ = try? await livePreparation?.value
        livePreparation = nil
        await liveManager?.cleanup(); liveManager = nil; speechModels = nil
    }
    func prepareLiveSpeech() async throws {
        if let livePreparation { try await livePreparation.value; return }
        let task = Task { try await self.loadLiveSpeech() }
        livePreparation = task
        do { try await task.value }
        catch { livePreparation = nil; throw error }
    }
    private func loadLiveSpeech() async throws {
        try await prepareSpeech()
        guard liveManager == nil else { return }
        guard let speechModels else { throw FoodError.database("Распознавание не подготовлено.") }
        let manager = AsrManager()
        let span = VoicePreparationTrace.Span("fluid-audio.loadModels")
        do {
            try await manager.loadModels(speechModels)
            try Task.checkCancellation()
            liveManager = manager
            span.finish()
        } catch {
            await manager.cleanup()
            span.finish("error: " + error.localizedDescription)
            throw error
        }
    }

    func transcribeLive(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        try await prepareLiveSpeech()
        guard let liveManager else { throw CancellationError() }
        var state = try TdtDecoderState()
        let span = tracedFirstInference ? nil : VoicePreparationTrace.Span("first-audio-inference")
        var outcome = "error-or-cancelled"
        defer { span?.finish(outcome) }
        let result = try await liveManager.transcribe(LiveASRInput.padded(samples, minimum: ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)), decoderState: &state, language: nil)
        outcome = "ok"; tracedFirstInference = true
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func transcribe(_ url: URL, retainingModels: Bool = false) async throws -> String {
        try await prepareSpeech()
        guard let models = speechModels else { throw FoodError.database("Повторите подготовку распознавания.") }
        if !retainingModels { speechModels = nil }
        let manager = AsrManager()
        try await manager.loadModels(models)
        var state = try TdtDecoderState()
        do {
            let result = try await manager.transcribe(url, decoderState: &state, language: nil)
            await manager.cleanup()
            try Task.checkCancellation()
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw FoodError.database("Речь не распознана. Запись сохранена — можно повторить обработку.") }
            return text
        } catch { await manager.cleanup(); throw error }
    }
    func extract(_ transcript: String) async throws -> ProductExtraction {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, transcript.count <= 6_000 else {
            throw FoodError.database("Введите описание одного продукта, не длиннее 6000 символов.")
        }
        #if targetEnvironment(simulator)
        throw FoodError.database("Qwen работает на физическом iPhone. В симуляторе доступно ручное создание карточки.")
        #else
        let directory: URL
        if let languageModelDirectory { directory = languageModelDirectory }
        else { directory = try await assets.directory("qwen") }
        guard let revision = try VoiceManifest.bundled().models.first(where: { $0.id == "qwen" })?.revision else {
            throw FoodError.database("В сборке отсутствует описание Qwen.")
        }
        let result = try await VoiceLanguageModel.extract(transcript, system: Self.prompt(),
            modelDirectory: directory, modelRevision: revision,
            cacheDirectory: languageModelDirectory == nil ? VoicePromptCache.directory : nil)
        #if DEBUG
        print("CACALC_QWEN: load=\(result.loadSeconds); inference=\(result.generationSeconds); cached=\(result.cacheHit); prefix=\(result.cachedTokens); peak=\(GPU.peakMemory); thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        #endif
        return result.extraction
        #endif
    }
    static func prompt() throws -> String {
        guard let url = Bundle.main.url(forResource: "product-extraction-prompt", withExtension: "txt") else {
            throw FoodError.database("В сборке отсутствуют инструкции голосового ввода.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

#if DEBUG
/// Explicit, synthetic startup experiment. Never adds audio or rows to the journal.
@MainActor enum VoiceStartupProbe {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--asr-startup-probe-cpu") }
    private static var ran = false
    static func run() async {
        guard !ran else { return }; ran = true
        let span = VoicePreparationTrace.Span("probe.cpu.total")
        let engine = VoiceEngine(assets: .shared, speechComputeUnits: .cpuOnly)
        do {
            guard try await VoiceAssets.shared.isReady(models: ["parakeet"]) else {
                span.finish("missing-models"); return
            }
            try await engine.prepareSpeech()
            // Fixed 3 seconds of silence: tests startup/encoder cost, not speech accuracy.
            _ = try await engine.transcribeLive([Float](repeating: 0, count: 48_000))
            let input = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceDiagnostics/startup-probe.aiff")
            if FileManager.default.fileExists(atPath: input.path) {
                let speech = VoicePreparationTrace.Span("probe.cpu.synthetic-speech")
                do {
                    let result = try await engine.transcribe(input, retainingModels: true)
                    speech.finish("synthetic-text: " + result)
                } catch { speech.finish("error: " + error.localizedDescription); throw error }
            }
            span.finish()
        } catch { span.finish("error: " + error.localizedDescription) }
        await engine.releaseSpeech()
    }
}
#endif
