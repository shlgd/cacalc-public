import Foundation
import CoreML

// Explicit local probe of the production VoiceEngine. Only synthetic audio.
@main struct ModelBench {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("MODEL_ROOT SYNTHETIC_WAV OUTPUT_JSON") }
        let manifest = try JSONDecoder().decode(VoiceManifest.self, from: Data(contentsOf: URL(fileURLWithPath: "ios/Resources/voice-models.json")))
        let assets = VoiceAssets(root: URL(fileURLWithPath: CommandLine.arguments[1]), manifest: manifest)
        guard try await assets.isReady(models: ["parakeet"]) else { throw FoodError.database("Pinned local weights are missing") }
        let wave = try LiveWave.read(URL(fileURLWithPath: CommandLine.arguments[2]), from: 0, finalized: true, limit: Int.max)
        guard wave.samples.count >= 16_000 else { throw FoodError.database("Synthetic WAV must contain at least one second of audio") }
        var report: [String: Any] = ["platform": "Mac", "audioSeconds": Double(wave.samples.count) / 16_000,
                                     "weights": "canonical pinned Parakeet v3; no download"]
        func memory(_ stage: String) { report[stage + "_memory"] = ProcessMemory.fields() }
        memory("baseline")
        let one = VoiceEngine(assets: assets)
        var began = Date(); try await one.prepareLiveSpeech(); report["firstPrepareSeconds"] = Date().timeIntervalSince(began)
        memory("onePrepared")
        began = Date(); let reference = try await one.transcribeLive(wave.samples)
        report["firstInferenceSeconds"] = Date().timeIntervalSince(began); report["reference"] = reference
        memory("oneInferred")
        let two = VoiceEngine(assets: assets)
        began = Date(); try await two.prepareLiveSpeech(); report["secondPrepareSeconds"] = Date().timeIntervalSince(began)
        _ = try await two.transcribeLive(wave.samples); memory("twoInferred")
        await two.releaseSpeech(); memory("secondReleased")
        // Same growing-prefix workload as previews, compared with bounded preview count.
        var prefixes: [[String: Any]] = []
        for seconds in [2, 4, 8, 12, 16, 24, 32, 48] where seconds * 16_000 <= wave.samples.count {
            let count = min(seconds * 16_000, wave.samples.count)
            let start = Date(); let text = try await one.transcribeLive(Array(wave.samples.prefix(count)))
            prefixes.append(["samples": count, "seconds": Date().timeIntervalSince(start), "text": text])
        }
        report["growingPrefixes"] = prefixes
        report["workload"] = "\(wave.samples.count / 16_000)s synthetic growing prefix; one-second sampling; excludes quiet boundaries and wall-clock cooldown"
        var oldSchedule: [[String: Any]] = [], oldFinal = ""
        let duration = wave.samples.count / 16_000
        for seconds in Array(1...duration) + [duration] {
            let start = Date(); oldFinal = try await one.transcribeLive(Array(wave.samples.prefix(seconds * 16_000)))
            oldSchedule.append(["audioSeconds": seconds, "seconds": Date().timeIntervalSince(start)])
        }
        report["oldPreviewsAndFinal"] = oldSchedule
        var cadence = LivePreviewCadence(), chosen: [Int] = []
        for seconds in 1...duration {
            if cadence.ready(samples: seconds * 16_000) { chosen.append(seconds); cadence.completed(samples: seconds * 16_000) }
        }
        // A single final pass is always performed, regardless of preview cadence.
        var scheduled: [[String: Any]] = []
        var newFinal = ""
        for seconds in chosen + [duration] {
            let count = seconds * 16_000
            let start = Date(); newFinal = try await one.transcribeLive(Array(wave.samples.prefix(count)))
            scheduled.append(["audioSeconds": seconds, "seconds": Date().timeIntervalSince(start)])
        }
        report["scheduledPreviewsAndFinal"] = scheduled
        report["oldPreviewAudioSeconds"] = (1...duration).reduce(0, +) + duration
        report["newPreviewAudioSeconds"] = chosen.reduce(0, +) + duration
        report["finalTranscriptionUnchanged"] = newFinal == oldFinal && newFinal == reference
        await one.releaseSpeech(); memory("allReleased")
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
        print("MODEL_LIFECYCLE_MAC " + String(decoding: data, as: UTF8.self))
    }
}
