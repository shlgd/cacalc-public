import Foundation

@main struct Checks {
    static func main() async throws {
        var clock = UsageScreenClock()
        precondition(clock.checkpoint(now: 1) == nil)
        precondition(clock.set(screen: "diary", active: true, now: 10) == nil)
        precondition(clock.checkpoint(now: 25) == 15)
        precondition(clock.set(screen: "editor", active: true, now: 30) == 5)
        precondition(clock.set(screen: "editor", active: false, now: 40) == 10)
        precondition(clock.checkpoint(now: 100) == nil)
        precondition(clock.set(screen: "editor", active: true, now: 200) == nil)
        precondition(clock.checkpoint(now: 207) == 7)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = UsageJournal(directory: dir)
        var first: [String: String] = [:]
        for i in 0..<200 {
            let event = ["eventID": UUID().uuidString, "time": "2026-09-16T10:00:00Z", "event": "syntheticTest", "sequence": String(i)]
            if i == 0 { first = event }
            journal.append(event)
        }
        journal.append(first)
        let flushed = await journal.flush()
        precondition(flushed)
        let files = try journal.savedEvents()
        precondition(files.count == 200)
        let sequences = Set(files.compactMap { Int($0["sequence"] ?? "") })
        precondition(sequences == Set(0..<200))
        // A blocked destination must retain queued events and retry after recovery.
        let blocked = dir.appendingPathComponent("blocked")
        try Data("occupied".utf8).write(to: blocked)
        let retry = UsageJournal(directory: blocked)
        retry.append(first)
        let failed = await retry.flush()
        precondition(!failed)
        try FileManager.default.removeItem(at: blocked)
        let recovered = await retry.flush()
        precondition(recovered)
        let reopened = UsageJournal(directory: blocked)
        reopened.append(first)
        let reopenedOK = await reopened.flush()
        precondition(reopenedOK)
        let reopenedCount = try reopened.savedEvents().count
        precondition(reopenedCount == 1)
        let bounded = DurableEventJournal(path: dir.appendingPathComponent("bounded.sqlite"), retention: .init(payloadBytes: 2000, count: 10, days: 30, diskBytes: 16_384))
        let now = ISO8601DateFormatter().string(from: Date())
        let recent = (0..<300).map { ["eventID": UUID().uuidString, "time": now, "event": "bounded", "sequence": String($0)] }
        try bounded.append(recent, stream: "usage")
        let retained = try bounded.events(stream: "usage")
        precondition(retained.count <= 10 && retained.last?["sequence"] == "299")
        let old = DurableEventJournal(path: dir.appendingPathComponent("expired.sqlite"))
        try old.append([["eventID": UUID().uuidString, "time": "2000-01-01T00:00:00Z", "event": "expired"]], stream: "usage")
        let expired = try old.events(stream: "usage"); precondition(expired.isEmpty)
        print("PASS: foreground time, screen changes, background exclusion, 200 durable events, deduplication, I/O recovery, reopen")
    }
}
