import Foundation
import CryptoKit

struct VoiceManifest: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        struct File: Decodable, Sendable { let path: String; let bytes: Int64; let sha256: String }
        let id: String
        let repository: String
        let revision: String
        let files: [File]
    }
    let version: Int
    let models: [Model]
    var totalBytes: Int64 { models.flatMap(\.files).reduce(0) { $0 + $1.bytes } }
    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "voice-models", withExtension: "json") else {
            throw FoodError.database("В сборке нет описания голосовых моделей.")
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard manifest.version == 1, Set(manifest.models.map(\.id)) == ["parakeet", "qwen"],
              manifest.models.allSatisfy({ model in
                  model.revision.count == 40 && model.files.allSatisfy {
                      !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..") && $0.sha256.count == 64
                  }
              }) else { throw FoodError.database("Некорректное описание голосовых моделей.") }
        return manifest
    }
}

private final class VoiceDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let update: @Sendable (Int64) -> Void
    init(_ update: @escaping @Sendable (Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { update(totalBytesWritten) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

actor VoiceAssets {
    static let shared = VoiceAssets()
    private var verifiedModels = Set<String>()
    private var downloading = false
    private let root: URL
    private let suppliedManifest: VoiceManifest?
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoiceModels", isDirectory: true), manifest: VoiceManifest? = nil) {
        self.root = root; suppliedManifest = manifest
    }
    private func manifest() throws -> VoiceManifest { try suppliedManifest ?? VoiceManifest.bundled() }
    private func folder(_ model: VoiceManifest.Model) -> URL {
        root.appendingPathComponent(model.id + "-" + model.revision, isDirectory: true)
    }
    func directory(_ id: String) throws -> URL {
        guard verifiedModels.contains(id), let model = try manifest().models.first(where: { $0.id == id }) else {
            throw FoodError.database("Сначала подготовьте голосовые модели.")
        }
        return folder(model)
    }
    private struct VerifiedFile: Codable, Equatable {
        let path: String
        let sha256: String
        let bytes: Int64
        let modified: Date
        let created: Date
        let inode: UInt64
    }
    private func fingerprint(_ model: VoiceManifest.Model) -> [VerifiedFile]? {
        var result: [VerifiedFile] = []
        for file in model.files {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: folder(model).appendingPathComponent(file.path).path),
                  let bytes = attributes[.size] as? NSNumber, bytes.int64Value == file.bytes,
                  let modified = attributes[.modificationDate] as? Date,
                  let created = attributes[.creationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
            result.append(VerifiedFile(path: file.path, sha256: file.sha256, bytes: bytes.int64Value,
                                       modified: modified, created: created, inode: inode.uint64Value))
        }
        return result
    }
    private func receiptURL(_ model: VoiceManifest.Model) -> URL {
        folder(model).appendingPathComponent(".verified-files-v1.json")
    }
    func isReady(models requested: Set<String> = ["parakeet", "qwen"]) throws -> Bool {
        guard !requested.isEmpty else { return false }
        if requested.isSubset(of: verifiedModels) { return true }
        if FileManager.default.fileExists(atPath: root.path) {
            var location = root, values = URLResourceValues(); values.isExcludedFromBackup = true
            try location.setResourceValues(values)
        }
        let manifest = try manifest()
        guard !requested.isEmpty, requested.isSubset(of: Set(manifest.models.map(\.id))) else { return false }
        for model in manifest.models where requested.contains(model.id) && !verifiedModels.contains(model.id) {
            let started = ContinuousClock.now
            let span = VoicePreparationTrace.Span("verify-files." + model.id)
            var result = "invalid-or-missing"
            defer { span.finish(result) }
            guard let before = fingerprint(model) else { return false }
            let stored = (try? Data(contentsOf: receiptURL(model))).flatMap { try? JSONDecoder().decode([VerifiedFile].self, from: $0) }
            let cached = stored == before
            if !cached {
                guard try model.files.allSatisfy({ try valid(folder(model).appendingPathComponent($0.path), file: $0) }),
                      fingerprint(model) == before else { return false }
                // A failed cache write only means another full verification next launch.
                if let data = try? JSONEncoder().encode(before) { try? data.write(to: receiptURL(model), options: .atomic) }
            }
            result = cached ? "metadata-cache-hit" : "sha256-verified"
            print("CACALC_ASR_VERIFY: model=\(model.id) cached=\(cached) duration=\(started.duration(to: .now))")
            verifiedModels.insert(model.id)
        }
        return true
    }
    private func valid(_ url: URL, file: VoiceManifest.Model.File) throws -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == file.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }
    func prepare(models requested: Set<String> = ["parakeet", "qwen"], progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard !downloading else { return }
        downloading = true
        defer { downloading = false }
        let manifest = try manifest(), fm = FileManager.default
        let models = manifest.models.filter { requested.contains($0.id) }
        guard !models.isEmpty, Set(models.map(\.id)) == requested else { throw FoodError.database("Неизвестная голосовая модель.") }
        let totalBytes = models.flatMap(\.files).reduce(Int64(0)) { $0 + $1.bytes }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root, flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try excluded.setResourceValues(flags)
        var completed: Int64 = 0
        for model in models {
            let label = model.id == "parakeet" ? "Parakeet" : "Qwen"
            for file in model.files {
                try Task.checkCancellation()
                let target = folder(model).appendingPathComponent(file.path)
                if try !valid(target, file: file) {
                    let url = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(file.path)")!
                    var request = URLRequest(url: url); request.timeoutInterval = 120
                    let previous = completed, total = totalBytes, expected = file.bytes
                    let delegate = VoiceDownloadProgress { written in
                        progress(Double(previous + min(written, expected)) / Double(total), label)
                    }
                    let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
                    defer { try? fm.removeItem(at: temporary) }
                    guard (response as? HTTPURLResponse)?.statusCode == 200, try valid(temporary, file: file) else {
                        throw FoodError.database("Файл \(label) не прошёл проверку. Повторите загрузку: готовые файлы сохранены.")
                    }
                    try Task.checkCancellation()
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: temporary) }
                    else { try fm.moveItem(at: temporary, to: target) }
                }
                completed += file.bytes
                progress(Double(completed) / Double(totalBytes), label)
            }
            verifiedModels.insert(model.id)
        }
    }
}

/// Small persistent startup trace; no audio or transcript. Each start is flushed before loading.
nonisolated enum VoicePreparationTrace {
    private static let lock = NSLock()
    private static let process = UUID().uuidString
    struct Span: Sendable {
        let id = UUID().uuidString
        let stage: String
        let started = ContinuousClock.now
        init(_ stage: String) {
            self.stage = stage
            VoicePreparationTrace.write(id: id, stage: stage, event: "start", fields: [:])
        }
        func finish(_ result: String = "ok") {
            VoicePreparationTrace.write(id: id, stage: stage, event: "end",
                fields: ["result": result, "duration": String(describing: started.duration(to: .now))])
        }
    }
    static func measure<T>(_ stage: String, _ work: () throws -> T) throws -> T {
        let span = Span(stage)
        do { let value = try work(); span.finish(); return value }
        catch { span.finish("error: " + error.localizedDescription); throw error }
    }
    private static func write(id: String, stage: String, event: String, fields: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceDiagnostics")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("preparation.jsonl")
            var values = fields
            values.merge(ProcessMemory.fields()) { _, new in new }
            values["stage"] = stage; values["event"] = event; values["span"] = id; values["process"] = process
            values["time"] = ISO8601DateFormatter().string(from: Date())
            values["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "test"
            var data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]); data.append(10)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
        } catch { NSLog("Voice preparation trace write failed: %@", error.localizedDescription) }
    }
}
