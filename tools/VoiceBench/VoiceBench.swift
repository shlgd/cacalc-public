import Foundation
import MLX
import MLXNN
import MLXLMCommon

private final class CacheTestModel: Module, LanguageModel, KVCacheDimensionProvider {
    let kvHeads = [1, 1]
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
}

/// Small synthetic tensors test disk failures without loading the language model.
private func checkCacheStorage() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("cacalc-cache-check-" + UUID().uuidString)
    defer { try? fm.removeItem(at: directory) }
    let disk = VoicePromptCache(directory: directory)
    let model = CacheTestModel()
    let tensors = model.newCache(parameters: nil)
    for case let item as KVCacheSimple in tensors {
        item.state = [MLXArray.zeros([1, 1, 256, 8]), MLXArray.ones([1, 1, 256, 8])]
    }
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "VoiceCacheChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    try require(disk.load(identity: "test", count: 256, model: model) == nil, "Missing cache")
    try disk.save(tensors, identity: "test", count: 256)
    let loaded = try disk.load(identity: "test", count: 256, model: model)
    try require(loaded?.count == 2 && loaded?.first?.offset == 256, "Round-trip cache")
    try require(loaded?.first?.state[1].sum().item(Float.self) == 2048, "Tensor contents")
    try require(disk.load(identity: "changed prompt", count: 256, model: model) == nil, "Prompt invalidation")
    try require(disk.load(identity: "test", count: 512, model: model) == nil, "Shape mismatch")
    let path = directory.appendingPathComponent("system.safetensors")
    var corrupted = try Data(contentsOf: path); corrupted[corrupted.count - 1] ^= 1
    try corrupted.write(to: path)
    try require(disk.load(identity: "test", count: 256, model: model) == nil, "Corrupt tensor checksum")
    try disk.save(tensors, identity: "replacement", count: 256)
    try require(disk.load(identity: "replacement", count: 256, model: model) != nil, "Replace bad cache")
    try Data("{}".utf8).write(to: directory.appendingPathComponent("system.json"))
    try require(disk.load(identity: "replacement", count: 256, model: model) == nil, "Corrupt receipt")
    // A file in place of a directory simulates a write failure without filling disk.
    let blocked = directory.appendingPathComponent("blocked")
    try Data().write(to: blocked)
    do {
        try VoicePromptCache(directory: blocked).save(tensors, identity: "test", count: 256)
        try require(false, "Expected write failure")
    } catch let error as NSError where error.domain != "VoiceCacheChecks" {}
    FileHandle.standardError.write(Data("Cache storage checks passed.\n".utf8))
}

/// Synthetic local comparisons using exactly the iPhone extraction implementation.
@main struct VoiceBench {
    struct Corpus: Decodable { let cases: [Case] }
    struct Case: Decodable {
        let id: String
        let text: String
        let expected: [String: String?]
        let name_excludes_brand: Bool?
    }
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5 || (arguments.count == 6 && arguments[5] == "cached-only") else {
            print("Usage: CacalcVoiceBench MODEL_DIRECTORY PROMPT_FILE CORPUS_JSON CACHE_DIRECTORY [cached-only]")
            return
        }
        try checkCacheStorage()
        let model = URL(fileURLWithPath: arguments[1])
        let system = try String(contentsOfFile: arguments[2], encoding: .utf8)
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
        let cache = URL(fileURLWithPath: arguments[4])
        // The caller supplies a dedicated benchmark cache; never read personal app data.
        var baseline: [String: String] = [:]
        var failures = 0
        for mode in arguments.count == 6 ? ["cached"] : ["uncached", "cached"] {
            for item in corpus.cases {
                let start = Date.timeIntervalSinceReferenceDate
                let result = try await VoiceLanguageModel.extract(item.text, system: system, modelDirectory: model,
                    modelRevision: model.lastPathComponent, cacheDirectory: mode == "cached" ? cache : nil)
                let value = result.extraction
                let actual: [String: String?] = ["name": value.name, "brand": value.brand,
                    "manufacturer": value.manufacturer, "basis": value.basis,
                    "protein": value.protein.map(Numbers.string), "fat": value.fat.map(Numbers.string),
                    "carbs": value.carbs.map(Numbers.string), "calories": value.calories.map(Numbers.string)]
                var errors = item.expected.compactMap { key, expected in
                    (actual[key] ?? nil) == expected ? nil : "\(key): expected \(expected ?? "null"), got \(actual[key] ?? nil ?? "null")"
                }
                if item.name_excludes_brand == true, let brand = value.brand,
                   value.name.localizedCaseInsensitiveContains(brand) { errors.append("Brand repeated in name") }
                if !item.expected.keys.contains("manufacturer"), value.manufacturer != nil { errors.append("Invented manufacturer") }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let json = String(decoding: try encoder.encode(value), as: UTF8.self)
                if mode == "uncached" { baseline[item.id] = json }
                else if let original = baseline[item.id], original != json { errors.append("Cache changed the decoded result") }
                failures += errors.isEmpty ? 0 : 1
                let record: [String: Any] = ["mode": mode, "id": item.id, "result": json, "errors": errors,
                    "seconds": Date.timeIntervalSinceReferenceDate - start, "load_seconds": result.loadSeconds,
                    "inference_seconds": result.generationSeconds, "cache_hit": result.cacheHit,
                    "cached_tokens": result.cachedTokens]
                var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                line.append(10)
                FileHandle.standardOutput.write(line)
            }
        }
        if failures > 0 { throw NSError(domain: "CacalcVoiceBench", code: failures, userInfo: [NSLocalizedDescriptionKey: "\(failures) failed cases"]) }
    }
}
