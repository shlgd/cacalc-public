import Foundation

struct HealthDay: Identifiable, Codable, Sendable {
    var date: Date
    var steps: Double?
    var activeEnergy: Double?
    var restingEnergy: Double?
    var id: Date { date }
    var totalEnergy: Double? {
        guard let activeEnergy, let restingEnergy else { return nil }
        return activeEnergy + restingEnergy
    }
}
struct SleepNight: Identifiable, Sendable {
    var start: Date
    var end: Date
    var seconds: Double
    var id: Date { end }
}
enum HealthInsights {
    static func nights(_ intervals: [DateInterval], now: Date) -> [SleepNight] {
        let sorted = intervals.filter { $0.duration > 0 && $0.end <= now }.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for part in sorted {
            if let last = merged.last, part.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, part.end))
            } else { merged.append(part) }
        }
        var episodes: [SleepNight] = []
        for part in merged {
            if let last = episodes.last, part.start.timeIntervalSince(last.end) <= 3600 {
                episodes[episodes.count - 1].end = part.end
                episodes[episodes.count - 1].seconds += part.duration
            } else { episodes.append(.init(start: part.start, end: part.end, seconds: part.duration)) }
        }
        let grouped = Dictionary(grouping: episodes.filter { $0.seconds >= 3 * 3600 }, by: { Day($0.end) })
        return grouped.values.compactMap { $0.max { $0.seconds < $1.seconds } }.sorted { $0.end < $1.end }
    }
    /// Circular mean: 23:50 and 00:10 should yield midnight, not midday.
    static func meanClock(_ dates: [Date], calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard !dates.isEmpty else { return nil }
        let angles = dates.map { Double(calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0)) / 1440 * 2 * Double.pi }
        let x = angles.reduce(0) { $0 + cos($1) }, y = angles.reduce(0) { $0 + sin($1) }
        guard hypot(x, y) / Double(dates.count) >= 0.25 else { return nil }
        let radians = atan2(y, x)
        let minutes = Int(((radians < 0 ? radians + 2 * .pi : radians) / (2 * .pi) * 1440).rounded()) % 1440
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
    static func mean(_ values: [Double?]) -> Double? {
        let available = values.compactMap { $0 }
        return available.isEmpty ? nil : available.reduce(0, +) / Double(available.count)
    }
}
