import UIKit

/// Opt-in, one-second startup timing; no audio or transcript enters the report.
@MainActor final class MealAnimationProbe: NSObject {
    static let shared = MealAnimationProbe()
    private var start: Double?
    private var events: [(String, Double)] = []
    private var frames: [Double] = []
    private var link: CADisplayLink?

    func begin() {
        guard ProcessInfo.processInfo.environment["CACALC_ANIMATION_PROBE"] == "1" else { return }
        link?.invalidate()
        start = CACurrentMediaTime()
        events = []; frames = []
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
        let run = start
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            guard start == run else { return }
            finish()
        }
    }

    func mark(_ name: String) {
        guard let start else { return }
        events.append((name, (CACurrentMediaTime() - start) * 1000))
    }

    @objc private func tick() {
        guard let start else { return }
        frames.append((CACurrentMediaTime() - start) * 1000)
    }

    private func finish() {
        link?.invalidate(); link = nil
        let markers = events.map { "\($0.0)=\(Int($0.1))ms" }.joined(separator: ", ")
        let times = ([0.0] + frames)
        let gaps = zip(times, times.dropFirst()).filter { $0.1 - $0.0 > 35 }
            .map { "\(Int($0.0))–\(Int($0.1))ms" }.joined(separator: ", ")
        print("MEAL_ANIMATION_PROBE events: \(markers)")
        print("MEAL_ANIMATION_PROBE firstCallback=\(Int(frames.first ?? -1))ms callbacks=\(frames.count) gaps>35ms: \(gaps)")
        start = nil
    }
}
