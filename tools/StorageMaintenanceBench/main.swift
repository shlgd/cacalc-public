import Foundation
import Compression
import SQLite3
import CryptoKit

@main struct MaintenanceChecks {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let root = home.appendingPathComponent("Documents/DictationArchive")
        try fm.createDirectory(at: root.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        let name = UUID().uuidString + ".json", json = root.appendingPathComponent(name)
        let raw = Data(String(repeating: "synthetic-log", count: 1000).utf8)
        try raw.write(to: json)
        let audio = root.appendingPathComponent("Audio/keep.wav"); try raw.write(to: audio)
        let diary = home.appendingPathComponent("Library/Application Support/default.store")
        try fm.createDirectory(at: diary.deletingLastPathComponent(), withIntermediateDirectories: true); try raw.write(to: diary)
        let usage = home.appendingPathComponent("Documents/UsageArchive/2026-10-05")
        try fm.createDirectory(at: usage, withIntermediateDirectories: true)
        let other = usage.appendingPathComponent(UUID().uuidString + ".json"); try Data("{}".utf8).write(to: other)
        let cache = home.appendingPathComponent(StorageMaintenance.cacheRelative + "/OS/key/old.tmp.bundle")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true); try raw.write(to: cache.appendingPathComponent("weights.bin"))
        for _ in 0..<10_000 { try Data(String(repeating: "synthetic", count: 45).utf8).write(to: usage.appendingPathComponent(UUID().uuidString + ".json")) }
        let started = Date()
        try StorageMaintenance.archive(home: home) { _ in }
        print("Archive 10002 synthetic files on Mac: \(Date().timeIntervalSince(started)) seconds")
        let archive = home.appendingPathComponent(StorageMaintenance.archiveRelative)
        let digest = try StorageMaintenance.fileHash(archive)
        if CommandLine.arguments.count > 1 { try fm.copyItem(at: archive, to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        var db: OpaquePointer?; sqlite3_open(archive.path, &db); defer { sqlite3_close(db) }
        var stmt: OpaquePointer?; sqlite3_prepare_v2(db, "SELECT payload,raw_bytes,codec FROM files WHERE raw_bytes>1000", -1, &stmt, nil); defer { sqlite3_finalize(stmt) }
        precondition(sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 2) == 1)
        let size = Int(sqlite3_column_int64(stmt, 1)); var decoded = Data(count: size)
        let n = decoded.withUnsafeMutableBytes { compression_decode_buffer($0.bindMemory(to: UInt8.self).baseAddress!, size, sqlite3_column_blob(stmt, 0)!.assumingMemoryBound(to: UInt8.self), Int(sqlite3_column_bytes(stmt, 0)), nil, COMPRESSION_ZLIB) }
        precondition(n == size && decoded == raw)
        do { try StorageMaintenance.clean(home: home, expectedHash: String(repeating: "0", count: 64)) { _ in }; preconditionFailure("Wrong verification accepted") } catch {}
        precondition(fm.fileExists(atPath: json.path))
        try Data("changed".utf8).write(to: json)
        do { try StorageMaintenance.clean(home: home, expectedHash: digest) { _ in }; preconditionFailure("Changed file deleted") } catch {}
        precondition(fm.fileExists(atPath: json.path))
        try raw.write(to: json)
        let saved = root.appendingPathComponent("preserved-original.bin")
        try fm.moveItem(at: json, to: saved)
        try fm.createSymbolicLink(at: json, withDestinationURL: audio)
        do { try StorageMaintenance.clean(home: home, expectedHash: digest) { _ in }; preconditionFailure("Leaf symlink accepted") } catch {}
        let linkTarget = try fm.destinationOfSymbolicLink(atPath: json.path); precondition(linkTarget == audio.path)
        try fm.removeItem(at: json); try fm.moveItem(at: saved, to: json)
        let moved = home.appendingPathComponent("saved-archive-directory")
        try fm.moveItem(at: root, to: moved)
        try fm.createSymbolicLink(at: root, withDestinationURL: moved)
        do { try StorageMaintenance.clean(home: home, expectedHash: digest) { _ in }; preconditionFailure("Parent symlink accepted") } catch {}
        precondition(fm.fileExists(atPath: moved.appendingPathComponent(name).path))
        try fm.removeItem(at: root); try fm.moveItem(at: moved, to: root)
        let memoryBefore = Int64(ProcessMemory.fields()["physicalFootprintBytes"]!)!
        try StorageMaintenance.clean(home: home, expectedHash: digest) { _ in }
        let memoryAfter = Int64(ProcessMemory.fields()["physicalFootprintBytes"]!)!
        precondition(memoryAfter - memoryBefore < 32 * 1024 * 1024, "Cleanup must not retain temporary Foundation objects across records")
        print("Cleanup footprint growth for 10002 files: \(memoryAfter - memoryBefore) bytes")
        // Restarting deletion after a partial cleanup is safe and bounded.
        let replayStart = Date()
        var replay = StorageMaintenance.Progress(stage: "test")
        try StorageMaintenance.clean(home: home, expectedHash: digest) { replay = $0 }
        precondition(replay.checkedFiles == 10002 && replay.missingFiles == 10002 && replay.files == 0)
        precondition(Date().timeIntervalSince(replayStart) < 10, "Replay of absent records must not resolve missing paths")
        print("Replay of 10002 missing files: \(Date().timeIntervalSince(replayStart)) seconds")
        precondition(!fm.fileExists(atPath: json.path) && !fm.fileExists(atPath: other.path))
        let cacheBytes = try StorageMaintenance.cacheSize(home: home); precondition(cacheBytes == 0)
        let keptAudio = try Data(contentsOf: audio), keptDiary = try Data(contentsOf: diary); precondition(keptAudio == raw && keptDiary == raw)
        precondition(!StorageMaintenance.isLegacy("Documents/DictationArchive/Audio/" + name))
        precondition(!StorageMaintenance.isLegacy("Documents/UsageArchive/../../" + name))
        precondition(!StorageMaintenance.isLegacy("Library/Application Support/default.store"))
        let big = home.appendingPathComponent("synthetic-large-file.bin")
        fm.createFile(atPath: big.path, contents: nil)
        let writer = try FileHandle(forWritingTo: big)
        let block = Data(repeating: 90, count: 1024 * 1024)
        var expected = SHA256()
        for _ in 0..<256 { try writer.write(contentsOf: block); expected.update(data: block) }
        try writer.close()
        let hashMemoryBefore = Int64(ProcessMemory.fields()["physicalFootprintBytes"]!)!
        let actual = try StorageMaintenance.fileHash(big)
        let hashMemoryAfter = Int64(ProcessMemory.fields()["physicalFootprintBytes"]!)!
        let expectedHash = expected.finalize().map { String(format: "%02x", $0) }.joined()
        precondition(actual == expectedHash)
        precondition(hashMemoryAfter - hashMemoryBefore < 32 * 1024 * 1024, "Streaming archive hash must release each NSData chunk")
        print("256 MiB file hash footprint growth: \(hashMemoryAfter - hashMemoryBefore) bytes")
        print("PASS: compressed roundtrip, wrong approval, changed original, resumable deletion, Audio/diary preservation, exact cache root, path allowlist")
    }
}
