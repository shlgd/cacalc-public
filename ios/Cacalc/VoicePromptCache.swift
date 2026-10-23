import Foundation
import CryptoKit

/// Only complete prefill blocks of the system message are reusable. Keeping the
/// same block boundaries avoids changing the arithmetic of the uncached path.
enum VoicePromptPrefix {
    static let step = 256
    static func tokens(system: [Int], full: [Int]) -> [Int] {
        guard full.starts(with: system) else { return [] }
        return Array(system.prefix(system.count / step * step))
    }
    static func identity(model: String, tokens: [Int]) -> String {
        let content = "voice-prefix-v1|mlx-0.29.1|lm-2.29.3|\(model)|" + tokens.map(String.init).joined(separator: ",")
        return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

#if !targetEnvironment(simulator)
import MLX
import MLXLMCommon

/// A disposable cache of public app instructions, never dictations or answers.
/// The model itself is still released after every extraction.
struct VoicePromptCache {
    struct Receipt: Codable {
        let identity: String
        let sha256: String
    }
    let directory: URL
    private var tensorURL: URL { directory.appendingPathComponent("system.safetensors") }
    private var receiptURL: URL { directory.appendingPathComponent("system.json") }

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoicePromptCache/v1", isDirectory: true)
    }

    func load(identity: String, count: Int, model: any LanguageModel) throws -> [KVCache]? {
        let fm = FileManager.default
        guard let receiptSize = try? fm.attributesOfItem(atPath: receiptURL.path)[.size] as? NSNumber,
              receiptSize.intValue > 0, receiptSize.intValue < 1024,
              let data = try? Data(contentsOf: receiptURL), data.count < 1024,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.identity == identity,
              let size = try? fm.attributesOfItem(atPath: tensorURL.path)[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= 256 * 1024 * 1024 else { return nil }
        try Task.checkCancellation()
        guard try checksum(tensorURL) == receipt.sha256 else { return nil }
        let (arrays, metadata) = try loadArraysAndMetadata(url: tensorURL)
        let cache = model.newCache(parameters: nil)
        guard !cache.isEmpty, arrays.count == cache.count * 2, metadata["identity"] == identity,
              let dimensions = model as? any KVCacheDimensionProvider,
              dimensions.kvHeads.count == cache.count else { return nil }
        for (index, item) in cache.enumerated() {
            guard let layer = item as? KVCacheSimple, let keys = arrays["\(index).k"], let values = arrays["\(index).v"],
                  keys.ndim == 4, values.shape == keys.shape,
                  keys.dim(0) == 1, keys.dim(1) == dimensions.kvHeads[index], keys.dim(2) == count,
                  keys.dim(3) > 0, keys.dim(3) <= 512,
                  [.float16, .bfloat16, .float32].contains(keys.dtype), values.dtype == keys.dtype else { return nil }
            layer.state = [keys, values]
        }
        try Task.checkCancellation()
        return cache
    }

    func save(_ cache: [KVCache], identity: String, count: Int) throws {
        guard !cache.isEmpty, cache.allSatisfy({ $0 is KVCacheSimple && $0.offset == count }) else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var arrays: [String: MLXArray] = [:]
        for (index, item) in cache.enumerated() {
            let state = item.state
            guard state.count == 2 else { return }
            arrays["\(index).k"] = state[0]; arrays["\(index).v"] = state[1]
        }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".safetensors")
        defer { try? fm.removeItem(at: temporary) }
        try MLX.save(arrays: arrays, metadata: ["identity": identity], url: temporary)
        let receipt = Receipt(identity: identity, sha256: try checksum(temporary))
        try Task.checkCancellation()
        if fm.fileExists(atPath: tensorURL.path) { _ = try fm.replaceItemAt(tensorURL, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: tensorURL) }
        // A crash between these writes leaves a cache miss, never trusted mixed data.
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
    }

    private func checksum(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
