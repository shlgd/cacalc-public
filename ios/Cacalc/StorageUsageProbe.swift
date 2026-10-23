import Foundation
import Darwin

/// Explicit metadata-only scan. Never opens file contents or removes an entry.
enum StorageUsageProbe {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--storage-usage-probe") }
    struct Totals: Codable, Sendable {
        var files: Int64 = 0
        var directories: Int64 = 0
        var symlinks: Int64 = 0
        var logicalBytes: Int64 = 0
        var statAllocatedBytes: Int64 = 0
        var resourceAllocatedBytes: Int64 = 0
        var resourceTotalAllocatedBytes: Int64 = 0
        var resourceMeasuredFiles: Int64 = 0
        var resourceMissingFiles: Int64 = 0
        var errors: Int64 = 0
        var multiplyLinkedFiles: Int64 = 0
    }
    struct Report: Codable, Sendable {
        var version = 1
        var build: String
        var complete = false
        var startedAt = Date()
        var updatedAt = Date()
        var elapsedSeconds: Double = 0
        var visited: Int64 = 0
        var groups: [String: Totals] = [:]
        var failure: String?
    }
    static func group(_ relative: String, bundle: Bool) -> String {
        if bundle { return "AppBundle" }
        for prefix in ["Documents/DictationArchive/Audio", "Documents/DictationArchive", "Documents/UsageArchive",
                       "Documents/DailyBackups", "Library/Application Support/VoiceModels",
                       "Library/Application Support/DiagnosticEvents", "Library/Application Support/HealthArchive",
                       "Library/Application Support/VoiceDiagnostics"] {
            if relative == prefix || relative.hasPrefix(prefix + "/") { return prefix }
        }
        let cache = "Library/Caches/local.cacalc.app/com.apple.e5rt.e5bundlecache"
        if relative == cache || relative.hasPrefix(cache + "/") {
            return relative.contains(".tmp.") ? "CoreML/temporary-named" : "CoreML/other"
        }
        if relative.hasPrefix("Library/Application Support/default.store") { return "Diary" }
        if relative.hasPrefix("Library/Caches/") { return "OtherCaches" }
        return relative.split(separator: "/").first.map(String.init) ?? "ContainerRoot"
    }
    static func scan(home: URL, bundle: URL?, output: URL, build: String,
                     maxSeconds: Double = 900) throws -> Report {
        var report = Report(build: build)
        let started = ProcessInfo.processInfo.systemUptime
        var savedAt = started
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        func save() throws {
            report.updatedAt = Date()
            report.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
            try encoder.encode(report).write(to: output, options: .atomic)
            savedAt = ProcessInfo.processInfo.systemUptime
        }
        func visit(_ path: String, relative: String, inBundle: Bool, depth: Int) throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - started < maxSeconds else {
                throw NSError(domain: "StorageUsageProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Scan time limit reached"])
            }
            // The only writes are this report and its Foundation atomic-write sibling.
            if path == output.path || path.hasPrefix(output.path + ".") { return }
            let key = group(relative, bundle: inBundle)
            var total = report.groups[key, default: Totals()]
            var info = stat()
            guard lstat(path, &info) == 0 else {
                total.errors += 1; report.groups[key] = total; return
            }
            report.visited += 1
            total.statAllocatedBytes += Int64(info.st_blocks) * 512
            let kind = info.st_mode & S_IFMT
            if kind == S_IFREG {
                total.files += 1
                total.logicalBytes += Int64(info.st_size)
                if info.st_nlink > 1 { total.multiplyLinkedFiles += 1 }
                autoreleasepool {
                    if let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey]),
                       let allocated = values.fileAllocatedSize, let all = values.totalFileAllocatedSize {
                        total.resourceAllocatedBytes += Int64(allocated)
                        total.resourceTotalAllocatedBytes += Int64(all)
                        total.resourceMeasuredFiles += 1
                    } else { total.resourceMissingFiles += 1 }
                }
            } else if kind == S_IFLNK { total.symlinks += 1 }
            else if kind == S_IFDIR { total.directories += 1 }
            report.groups[key] = total
            if ProcessInfo.processInfo.systemUptime - savedAt >= 3 { try save() }
            guard kind == S_IFDIR else { return } // Never follow symlinks outside the container.
            guard depth < 128, let directory = opendir(path) else {
                report.groups[key, default: Totals()].errors += 1; return
            }
            defer { closedir(directory) }
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { report.groups[key, default: Totals()].errors += 1 }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                try visit(path + "/" + name, relative: relative.isEmpty ? name : relative + "/" + name,
                          inBundle: inBundle, depth: depth + 1)
            }
        }
        try save()
        do {
            try visit(home.path, relative: "", inBundle: false, depth: 0)
            if let bundle { try visit(bundle.path, relative: "", inBundle: true, depth: 0) }
            report.complete = report.groups.values.allSatisfy { $0.errors == 0 && $0.resourceMissingFiles == 0 }
        } catch { report.failure = error.localizedDescription }
        try save()
        return report
    }
    static func run() async -> Report? {
        let output = URL.applicationSupportDirectory.appendingPathComponent("storage-usage-probe.json")
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return await Task.detached(priority: .utility) {
            try? scan(home: URL(fileURLWithPath: NSHomeDirectory()), bundle: Bundle.main.bundleURL,
                      output: output, build: build)
        }.value
    }
}

import SQLite3
import CryptoKit
import Compression

/// Maintenance runs before SwiftData, logging and model loading. Only allowlisted legacy
/// JSON files can be removed, and only after a complete archive was verified outside iPhone.
enum StorageMaintenance {
    static let archiveArgument = "--archive-legacy-logs"
    static let cleanupArgument = "--clean-verified-logs"
    static var enabled: Bool { let a = ProcessInfo.processInfo.arguments; return a.contains(archiveArgument) || a.contains(cleanupArgument) }
    static let archiveRelative = "Library/Application Support/StorageMaintenance/legacy-logs.sqlite"
    static let cacheRelative = "Library/Caches/local.cacalc.app/com.apple.e5rt.e5bundlecache"
    struct Progress: Codable, Sendable {
        var stage: String; var files: Int64 = 0; var bytes: Int64 = 0
        var checkedFiles: Int64 = 0; var missingFiles: Int64 = 0
        var finished = false; var error: String?
        var memory: [String: String]?
        var freeDiskBytes: Int64?
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "StorageMaintenance", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func fileHash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while true {
            // FileHandle returns autoreleased NSData; drain each chunk, not only the entire task.
            let count = try autoreleasepool {
                guard let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty else { return 0 }
                digest.update(data: bytes)
                return bytes.count
            }
            if count == 0 { break }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func isLegacy(_ relative: String) -> Bool {
        let p = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3 || p.count == 4, p[0] == "Documents", UUID(uuidString: String(p.last!.dropLast(5))) != nil, p.last!.hasSuffix(".json") else { return false }
        if p[1] == "DictationArchive" { return p.count == 3 }
        return p[1] == "UsageArchive" && p.count == 4 && p[2].range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
    /// Streaming traversal: never materialize a million filenames or follow symlinks.
    static func walk(_ url: URL, relative: String, visit: (URL, String, stat) throws -> Void) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { if errno == ENOENT { return }; throw failure("lstat: \(relative)") }
        if info.st_mode & S_IFMT == S_IFREG { try visit(url, relative, info); return }
        guard info.st_mode & S_IFMT == S_IFDIR else { return }
        guard let dir = opendir(url.path) else { throw failure("opendir: \(relative)") }; defer { closedir(dir) }
        while true {
            errno = 0
            guard let item = readdir(dir) else { if errno != 0 { throw failure("readdir: \(relative)") }; break }
            let name = withUnsafePointer(to: &item.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            // Audio and unknown directories are never traversed in the legacy exporter.
            if relative == "Documents/DictationArchive" && !name.hasSuffix(".json") { continue }
            try autoreleasepool { try walk(url.appendingPathComponent(name), relative: relative + "/" + name, visit: visit) }
        }
    }
    static func packed(_ raw: Data) -> (Data, Int32) {
        guard !raw.isEmpty else { return (raw, 0) }
        var destination = Data(count: raw.count)
        let size = destination.withUnsafeMutableBytes { out in raw.withUnsafeBytes { input in
            compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, raw.count, input.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
        } }
        if size == 0 || size >= raw.count { return (raw, 0) }
        destination.count = size; return (destination, 1) // raw DEFLATE, Python zlib.decompress(data, -15).
    }
    static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(String(cString: sqlite3_errmsg(db))) }
    }
    static func archive(home: URL, progress: (Progress) throws -> Void) throws {
        let path = home.appendingPathComponent(archiveRelative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(path.path, &handle) == SQLITE_OK, let db = handle else { throw failure("Open archive") }; defer { sqlite3_close(db) }
        try execute(db, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, raw_bytes INTEGER NOT NULL, sha256 TEXT NOT NULL, codec INTEGER NOT NULL, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL); DELETE FROM metadata WHERE key='complete'")
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO files VALUES(?,?,?,?,?)", -1, &insert, nil) == SQLITE_OK else { throw failure("Prepare archive") }; defer { sqlite3_finalize(insert) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var state = Progress(stage: "archiving")
        try progress(state); try execute(db, "BEGIN IMMEDIATE")
        do {
            for root in ["Documents/UsageArchive", "Documents/DictationArchive"] {
                try walk(home.appendingPathComponent(root), relative: root) { url, relative, info in
                    guard isLegacy(relative) else { return }
                    try autoreleasepool {
                        guard info.st_size <= 16 * 1024 * 1024 else { throw failure("Oversized legacy event: \(relative)") }
                        let raw = try Data(contentsOf: url), digest = hash(raw), (payload, codec) = packed(raw)
                        sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                        sqlite3_bind_text(insert, 1, relative, -1, transient)
                        sqlite3_bind_int64(insert, 2, Int64(raw.count)); sqlite3_bind_text(insert, 3, digest, -1, transient); sqlite3_bind_int(insert, 4, codec)
                        let result = payload.withUnsafeBytes { sqlite3_bind_blob(insert, 5, $0.baseAddress, Int32(payload.count), transient) }
                        guard result == SQLITE_OK, sqlite3_step(insert) == SQLITE_DONE else { throw failure("Archive write: \(relative)") }
                        state.files += 1; state.bytes += Int64(raw.count)
                    }
                    if state.files % 2000 == 0 { try execute(db, "COMMIT"); try progress(state); try execute(db, "BEGIN IMMEDIATE") }
                }
            }
            try execute(db, "INSERT OR REPLACE INTO metadata VALUES('complete','1'); COMMIT")
            state.finished = true; try progress(state)
        } catch { try? execute(db, "ROLLBACK"); throw error }
    }
    static func clean(home: URL, expectedHash: String, progress: (Progress) throws -> Void) throws {
        guard expectedHash.count == 64, try fileHash(home.appendingPathComponent(archiveRelative)) == expectedHash else { throw failure("External archive verification hash mismatch") }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent(archiveRelative).path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else { throw failure("Open verified archive") }; defer { sqlite3_close(db) }
        var sealed: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE key='complete'", -1, &sealed, nil); defer { sqlite3_finalize(sealed) }
        guard sqlite3_step(sealed) == SQLITE_ROW, String(cString: sqlite3_column_text(sealed, 0)) == "1" else { throw failure("Archive incomplete") }
        var cursor: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT path,raw_bytes,sha256 FROM files ORDER BY path", -1, &cursor, nil) == SQLITE_OK else { throw failure("Read archive manifest") }; defer { sqlite3_finalize(cursor) }
        var directoryHandles: [String: Int32] = [:]
        defer { for descriptor in directoryHandles.values { close(descriptor) } }
        func directoryHandle(_ parent: String) throws -> Int32 {
            if let descriptor = directoryHandles[parent] { return descriptor }
            let url = home.appendingPathComponent(parent)
            guard url.resolvingSymlinksInPath().path == url.path else { throw failure("Symlink in deletion directory") }
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw failure("Open deletion directory") }
            directoryHandles[parent] = descriptor
            return descriptor
        }
        var state = Progress(stage: "deleting-verified-legacy")
        try progress(state)
        while true {
            let result = sqlite3_step(cursor)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure("Archive manifest read") }
            try autoreleasepool {
                let relative = String(cString: sqlite3_column_text(cursor, 0)), digest = String(cString: sqlite3_column_text(cursor, 2))
                guard isLegacy(relative) else { throw failure("Unsafe archive path") }
                let parent = String(relative.prefix(upTo: relative.lastIndex(of: "/")!))
                let leaf = String(relative.suffix(from: relative.index(after: relative.lastIndex(of: "/")!)))
                let directory = try directoryHandle(parent)
                var info = stat()
                // Retain a verified parent descriptor. No full-path Foundation resolution
                // per file; fstatat/openat never follow a symlink at the leaf.
                if fstatat(directory, leaf, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT { state.missingFiles += 1; return }
                    throw failure("Read deletion target")
                }
                guard info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == sqlite3_column_int64(cursor, 1) else { throw failure("Legacy event changed: \(relative)") }
                let descriptor = openat(directory, leaf, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { throw failure("Open deletion target") }
                let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? reader.close() }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
                      opened.st_size == info.st_size, try hash(reader.readToEnd() ?? Data()) == digest else { throw failure("Legacy event changed: \(relative)") }
                guard unlinkat(directory, leaf, 0) == 0 else { throw failure("Unlink verified event") }
                state.files += 1; state.bytes += Int64(info.st_blocks) * 512
            }
            state.checkedFiles += 1
            if state.checkedFiles % 2000 == 0 { try progress(state) }
        }
        // Cache is entirely recreatable; models and Audio have different, protected roots.
        try clearCache(home: home)
        state.stage = "cleaned"; state.finished = true; try progress(state)
    }
    static func cacheSize(home: URL) throws -> Int64 {
        var size: Int64 = 0
        try walk(home.appendingPathComponent(cacheRelative), relative: cacheRelative) { _, _, info in size += Int64(info.st_blocks) * 512 }
        return size
    }
    static func clearCache(home: URL) throws {
        let root = home.appendingPathComponent(cacheRelative)
        guard root.resolvingSymlinksInPath().path == root.path else { throw failure("Cache root symlink") }
        try walk(root, relative: cacheRelative) { url, _, _ in guard unlink(url.path) == 0 else { throw failure("Unlink cache file") } }
        // Empty directories are harmless; keep them rather than recursive removeItem.
    }
    /// Once per cold process, before any MLModel can be constructed. High-water mark,
    /// not an OS quota: a compilation may temporarily exceed it until the next launch.
    static func boundColdCache(home: URL) throws {
        if try cacheSize(home: home) > 2 * 1024 * 1024 * 1024 { try clearCache(home: home) }
    }
    static func run() async -> String {
        await Task.detached(priority: .utility) {
            let home = URL(fileURLWithPath: NSHomeDirectory()), args = ProcessInfo.processInfo.arguments
            let output = home.appendingPathComponent("Library/Application Support/StorageMaintenance/progress.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            func save(_ state: Progress) throws {
                var checkpoint = state
                checkpoint.memory = ProcessMemory.fields()
                checkpoint.freeDiskBytes = (try? FileManager.default.attributesOfFileSystem(forPath: home.path)[.systemFreeSize] as? NSNumber)?.int64Value
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(checkpoint).write(to: output, options: .atomic)
            }
            do {
                if let index = args.firstIndex(of: cleanupArgument), args.indices.contains(index + 1) {
                    try clean(home: home, expectedHash: args[index + 1], progress: { state in
                        var checkpoint = state; checkpoint.finished = false; try save(checkpoint)
                    })
                    // The external verified copy is now canonical. No growing archive stays on iPhone.
                    try FileManager.default.removeItem(at: home.appendingPathComponent(archiveRelative))
                    try save(Progress(stage: "offloaded-and-cleaned", finished: true))
                } else if args.contains(archiveArgument) { try archive(home: home, progress: save) }
                else { throw failure("Missing verified hash") }
                return "Операция завершена. Отчёт сохранён."
            } catch { try? save(Progress(stage: "failed", finished: true, error: error.localizedDescription)); return "Операция остановлена: " + error.localizedDescription }
        }.value
    }
}
