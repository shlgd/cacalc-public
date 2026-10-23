import Foundation

/// Each immutable batch contains both the data and its continuation cursor.
/// A crash before the atomic write repeats the query; after it resumes at this cursor.
actor HealthArchive {
    static let shared = HealthArchive()
    struct Batch: Codable, Sendable {
        var version = 1
        var type: String
        var receivedAt: Date
        var anchor: Data
        var samples: Data
        var added: Int
        var deletedIDs: [UUID]
    }
    private let root: URL
    private var sequences: [String: UInt64] = [:]
    init(root: URL = URL.applicationSupportDirectory.appendingPathComponent("HealthArchive", isDirectory: true)) { self.root = root }
    func saveOverview(_ data: Data) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: root.appendingPathComponent("overview.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: root.appendingPathComponent("overview.json"), options: .atomic)
        #endif
    }
    private func directory(_ type: String) -> URL { root.appendingPathComponent(type, isDirectory: true) }
    private func files(_ type: String) throws -> [URL] {
        let folder = directory(type)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
    }
    private func sequence(_ url: URL) -> UInt64? {
        let parts = url.lastPathComponent.split(separator: "-")
        guard parts.count > 2, parts[0] == "seq" else { return nil }
        return UInt64(parts[1])
    }
    func latest(_ type: String) throws -> Batch? {
        let urls = try files(type)
        let ordered = urls.compactMap { url in sequence(url).map { (order: $0, url: url) } }
        let last: URL?
        if let newest = ordered.max(by: { $0.order < $1.order }) { last = newest.url }
        else {
            // Pre-sequence archives have no durable arrival counter. Use file write
            // times once, not receivedAt; equal legacy times have an explicit stable tie.
            let legacy = try urls.map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) }
            last = legacy.max { a, b in a.1 == b.1 ? a.0.lastPathComponent < b.0.lastPathComponent : a.1 < b.1 }?.0
        }
        guard let last else { return nil }
        return try JSONDecoder().decode(Batch.self, from: Data(contentsOf: last))
    }
    func save(_ batch: Batch) throws {
        let folder = directory(batch.type)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous: UInt64
        if let cached = sequences[batch.type] { previous = cached }
        else { previous = try files(batch.type).compactMap(sequence).max() ?? 0 }
        guard previous < UInt64.max else { throw FoodError.database("Переполнен порядок архива Здоровья.") }
        let next = previous + 1
        let name = "seq-" + String(format: "%020llu", next) + "-" + UUID().uuidString + ".json"
        let data = try JSONEncoder().encode(batch)
        #if os(iOS)
        try data.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        #endif
        sequences[batch.type] = next
    }
}
