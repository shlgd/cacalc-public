import Foundation
import OSLog
import SQLite3

/// Bounded diagnostics, separate from diary facts and the durable business audit.
final class DurableEventJournal: @unchecked Sendable {
    static let shared = DurableEventJournal(path: URL.applicationSupportDirectory
        .appendingPathComponent("DiagnosticEvents/events-v1.sqlite"))
    private let path: URL
    private let lock = NSLock()
    private var db: OpaquePointer?
    struct Retention: Sendable {
        var payloadBytes: Int64 = 64 * 1024 * 1024
        var count: Int64 = 100_000
        var days: Int = 30
        var diskBytes: Int64 = 128 * 1024 * 1024
    }
    private let retention: Retention
    private var maintenanceAt: Date = .distantPast
    private var appendedSinceMaintenance = 0
    init(path: URL, retention: Retention = Retention()) { self.path = path; self.retention = retention }
    deinit { if let db { sqlite3_close(db) } }
    private func failure(_ context: String) -> NSError {
        NSError(domain: "local.cacalc.diagnostics", code: Int(db.map(sqlite3_errcode) ?? SQLITE_ERROR),
                userInfo: [NSLocalizedDescriptionKey: context + ": " + (db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite unavailable")])
    }
    private func execute(_ sql: String) throws {
        guard let db, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure("Diagnostic journal") }
    }
    private func connection() throws -> OpaquePointer {
        if let db { return db }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        guard sqlite3_open_v2(path.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened else {
            if let opened { sqlite3_close(opened) }
            throw NSError(domain: "local.cacalc.diagnostics", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Не удалось открыть журнал событий."])
        }
        db = opened
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA busy_timeout=2000")
            try execute("PRAGMA journal_size_limit=16777216")
            try execute("CREATE TABLE IF NOT EXISTS events (sequence INTEGER PRIMARY KEY, stream TEXT NOT NULL, id TEXT NOT NULL, time TEXT NOT NULL, event TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(stream,id))")
            try execute("CREATE INDEX IF NOT EXISTS events_by_time ON events(stream,time,sequence)")
        } catch { sqlite3_close(opened); db = nil; throw error }
        return opened
    }
    func append(_ records: [[String: String]], stream: String) throws {
        guard !records.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let db = try connection()
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO events(stream,id,time,event,payload) VALUES(?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else {
                throw failure("Prepare event")
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for record in records {
                guard let id = record["eventID"], UUID(uuidString: id) != nil,
                      let time = record["time"], let event = record["event"] else {
                    throw NSError(domain: "local.cacalc.diagnostics", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Некорректное событие журнала."])
                }
                let payload = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                for (index, value) in [stream, id, time, event].enumerated() {
                    let bytes = Array(value.utf8)
                    guard bytes.withUnsafeBytes({ sqlite3_bind_text(statement, Int32(index + 1), $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(bytes.count), transient) }) == SQLITE_OK else {
                        throw failure("Bind event")
                    }
                }
                guard payload.withUnsafeBytes({ sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32(payload.count), transient) }) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else { throw failure("Write event") }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        appendedSinceMaintenance += records.count
        if appendedSinceMaintenance >= 256 || Date().timeIntervalSince(maintenanceAt) > 3600 {
            // A retention failure must not turn an already committed event into a retry.
            do { try maintain(); maintenanceAt = Date(); appendedSinceMaintenance = 0 }
            catch { UserDefaults.standard.set(error.localizedDescription, forKey: "diagnosticRetentionError") }
        }
    }
    private func scalar(_ sql: String) throws -> Int64 {
        let db = try connection(); var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure("Retention query") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure("Retention scalar") }
        return sqlite3_column_int64(statement, 0)
    }
    private func maintain() throws {
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(retention.days) * 86400))
        try execute("DELETE FROM events WHERE time < '\(cutoff)'")
        var count = try scalar("SELECT COUNT(*) FROM events")
        var bytes = try scalar("SELECT COALESCE(SUM(length(payload)),0) FROM events")
        while count > retention.count || bytes > retention.payloadBytes {
            // Keep newest events; bounded batches also work when a single snapshot is large.
            let excess = max(Int64(1), count - retention.count)
            let chunk = min(count, max(excess, min(1024, count / 10 + 1)))
            try execute("DELETE FROM events WHERE sequence IN (SELECT sequence FROM events ORDER BY sequence LIMIT \(chunk))")
            count = try scalar("SELECT COUNT(*) FROM events")
            bytes = try scalar("SELECT COALESCE(SUM(length(payload)),0) FROM events")
        }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let physical = (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if physical > retention.diskBytes { try execute("VACUUM"); try execute("PRAGMA wal_checkpoint(TRUNCATE)") }
        UserDefaults.standard.removeObject(forKey: "diagnosticRetentionError")
    }
    func events(stream: String) throws -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        let db = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM events WHERE stream=? ORDER BY sequence", -1, &statement, nil) == SQLITE_OK else {
            throw failure("Read events")
        }
        defer { sqlite3_finalize(statement) }
        let bytes = Array(stream.utf8), transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard bytes.withUnsafeBytes({ sqlite3_bind_text(statement, 1, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(bytes.count), transient) }) == SQLITE_OK else {
            throw failure("Bind stream")
        }
        var result: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard let pointer = sqlite3_column_blob(statement, 0) else { throw failure("Empty event") }
            result.append(try JSONDecoder().decode([String: String].self, from: Data(bytes: pointer, count: size)))
        }
        if sqlite3_errcode(db) != SQLITE_OK && sqlite3_errcode(db) != SQLITE_DONE { throw failure("Read events") }
        return result
    }
}

/// Same atomic, UUID-addressed event convention as DictationArchive, in a separate namespace.
/// All filesystem work and retries are serialized off the main thread.
final class UsageJournal: @unchecked Sendable {
    static let shared = UsageJournal(directory: URL.documentsDirectory.appendingPathComponent("UsageArchive"), journal: .shared)
    private let directory: URL
    private let journal: DurableEventJournal
    private let queue = DispatchQueue(label: "local.cacalc.usage-archive", qos: .utility)
    private var pending: [[String: String]] = []
    private var retryScheduled = false
    private var drainScheduled = false
    private let logger = Logger(subsystem: "local.cacalc.app", category: "UsageArchive")
    init(directory: URL, journal: DurableEventJournal? = nil) {
        self.directory = directory
        self.journal = journal ?? DurableEventJournal(path: directory.appendingPathComponent("events-v1.sqlite"))
    }

    func append(_ event: [String: String]) {
        queue.async {
            self.pending.append(event)
            guard !self.drainScheduled else { return }
            self.drainScheduled = true
            self.queue.asyncAfter(deadline: .now() + .milliseconds(40)) {
                self.drainScheduled = false
                self.drain()
            }
        }
    }
    func flush() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { self.drain(); continuation.resume(returning: self.pending.isEmpty) }
        }
    }
    private func drain() {
        do {
            while !pending.isEmpty {
                let batch = Array(pending.prefix(128))
                try journal.append(batch, stream: "usage")
                pending.removeFirst(batch.count)
            }
            UserDefaults.standard.removeObject(forKey: "usageArchiveError")
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: "usageArchiveError")
            logger.error("Usage archive write failed: \(error.localizedDescription, privacy: .public)")
            if !retryScheduled {
                retryScheduled = true
                queue.asyncAfter(deadline: .now() + 5) {
                    self.retryScheduled = false
                    self.drain()
                }
            }
        }
    }
    func savedEvents() throws -> [[String: String]] { try journal.events(stream: "usage") }
}

/// Monotonic time: foreground intervals never include time asleep or another screen.
struct UsageScreenClock {
    private(set) var screen = "startup"
    private var since: TimeInterval?
    mutating func checkpoint(now: TimeInterval) -> TimeInterval? {
        guard let since else { return nil }
        self.since = now
        return max(0, now - since)
    }
    mutating func set(screen: String, active: Bool, now: TimeInterval) -> TimeInterval? {
        let elapsed = checkpoint(now: now)
        self.screen = screen
        since = active ? now : nil
        return elapsed
    }
}
