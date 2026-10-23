import Foundation
import Darwin

@main struct StorageUsageChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-check-" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let outside = root.appendingPathComponent("outside")
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let directory = home.appendingPathComponent("Documents/DictationArchive")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let a = directory.appendingPathComponent("a.json")
        try Data("synthetic-event".utf8).write(to: a)
        try Data(repeating: 1, count: 20_000).write(to: outside.appendingPathComponent("not-in-container"))
        try fm.createSymbolicLink(at: directory.appendingPathComponent("outside"), withDestinationURL: outside)
        let audio = directory.appendingPathComponent("Audio")
        try fm.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 1000).write(to: audio.appendingPathComponent("test.wav"))
        let output = home.appendingPathComponent("report.json")
        let report = try StorageUsageProbe.scan(home: home, bundle: nil, output: output, build: "synthetic")
        precondition(report.complete && report.failure == nil)
        let json = report.groups["Documents/DictationArchive"]!
        precondition(json.files == 1 && json.symlinks == 1 && json.logicalBytes == 15)
        precondition(report.groups["Documents/DictationArchive/Audio"]!.logicalBytes == 1000)
        precondition(report.groups.values.reduce(0) { $0 + $1.files } == 2, "No symlink traversal or report self-count")
        let values = try a.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        precondition(json.resourceAllocatedBytes == Int64(values.fileAllocatedSize!))
        precondition(json.resourceTotalAllocatedBytes == Int64(values.totalFileAllocatedSize!))
        let preserved = try Data(contentsOf: a)
        precondition(preserved == Data("synthetic-event".utf8))
        let interrupted = try StorageUsageProbe.scan(home: home, bundle: nil, output: output, build: "synthetic", maxSeconds: 0)
        precondition(!interrupted.complete && interrupted.failure != nil)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(StorageUsageProbe.Report.self, from: Data(contentsOf: output))
        precondition(!saved.complete && saved.failure != nil)
        let flat = home.appendingPathComponent("Documents/UsageArchive/2026-01-01")
        try fm.createDirectory(at: flat, withIntermediateDirectories: true)
        for index in 0..<20_000 { try Data("{}".utf8).write(to: flat.appendingPathComponent("\(index).json")) }
        let many = try StorageUsageProbe.scan(home: home, bundle: nil, output: output, build: "synthetic")
        precondition(many.complete && many.groups["Documents/UsageArchive"]!.files == 20_000)
        precondition(many.groups["Documents/UsageArchive"]!.logicalBytes == 40_000)
        print("Storage probe PASS: real allocation APIs, audio split, symlink isolation, read-only inputs, report exclusion, interrupted progress, 20000 files in \(many.elapsedSeconds)s")
    }
}
