#if !targetEnvironment(simulator)
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Shared by the phone and the macOS benchmark; no network or diary access.
enum VoiceLanguageModel {
    struct Result: Sendable {
        let extraction: ProductExtraction
        let cacheHit: Bool
        let cachedTokens: Int
        let loadSeconds: Double
        let generationSeconds: Double
    }

    static func extract(_ transcript: String, system: String, modelDirectory: URL,
                        modelRevision: String, cacheDirectory: URL?) async throws -> Result {
        GPU.set(cacheLimit: 32 * 1024 * 1024)
        defer { GPU.clearCache() }
        let start = Date.timeIntervalSinceReferenceDate
        let container = try await LLMModelFactory.shared.loadContainer(configuration: .init(directory: modelDirectory))
        let loaded = Date.timeIntervalSinceReferenceDate
        try Task.checkCancellation()
        return try await container.perform { context in
            let full = try await context.processor.prepare(input: UserInput(chat: [.system(system), .user(transcript)],
                additionalContext: ["enable_thinking": false]))
            let systemTokens = try context.tokenizer.applyChatTemplate(
                messages: [["role": "system", "content": system]], chatTemplate: nil,
                addGenerationPrompt: false, truncation: false, maxLength: nil, tools: nil,
                additionalContext: ["enable_thinking": false])
            let prefix = VoicePromptPrefix.tokens(system: systemTokens, full: full.text.tokens.asArray(Int.self))
            var cache: [KVCache]?
            var cacheHit = false
            var cachedTokens = 0
            if let cacheDirectory, !prefix.isEmpty {
                let disk = VoicePromptCache(directory: cacheDirectory)
                let identity = VoicePromptPrefix.identity(model: modelRevision, tokens: prefix)
                do { cache = try disk.load(identity: identity, count: prefix.count, model: context.model) }
                catch is CancellationError { throw CancellationError() }
                catch { cache = nil } // Optional acceleration: a bad cache cannot block input.
                cacheHit = cache != nil
                if cache == nil {
                    let fresh = context.model.newCache(parameters: nil)
                    if !fresh.isEmpty, fresh.allSatisfy({ $0 is KVCacheSimple }) {
                        for offset in stride(from: 0, to: prefix.count, by: VoicePromptPrefix.step) {
                            try Task.checkCancellation()
                            let chunk = MLXArray(Array(prefix[offset..<(offset + VoicePromptPrefix.step)]))[.newAxis]
                            _ = context.model(chunk, cache: fresh)
                            eval(fresh)
                        }
                        try Task.checkCancellation()
                        // Save before any user tokens can enter these caches.
                        do { try disk.save(fresh, identity: identity, count: prefix.count) }
                        catch is CancellationError { throw CancellationError() }
                        catch {} // A full disk leaves normal extraction available.
                        cache = fresh
                    }
                }
                if cache != nil { cachedTokens = prefix.count }
            }
            try Task.checkCancellation()
            let input = cachedTokens > 0 ? LMInput(tokens: full.text.tokens[cachedTokens...]) : full
            let parameters = GenerateParameters(maxTokens: 256, temperature: 0, prefillStepSize: VoicePromptPrefix.step)
            let stream = try MLXLMCommon.generate(input: input, cache: cache, parameters: parameters, context: context)
            var output = ""
            for await generation in stream {
                try Task.checkCancellation()
                if case .chunk(let text) = generation { output += text }
            }
            try Task.checkCancellation()
            return Result(extraction: try ProductExtraction.decode(output), cacheHit: cacheHit,
                cachedTokens: cachedTokens, loadSeconds: loaded - start,
                generationSeconds: Date.timeIntervalSinceReferenceDate - loaded)
        }
    }
}
#endif
