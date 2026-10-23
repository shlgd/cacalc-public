import AVFoundation
import OSLog

/// Serializes blocking audio-session operations away from MainActor.
/// A stale completion cannot deactivate a newer recording's session.
actor VoiceAudioSession {
    static let shared = VoiceAudioSession()
    private var owner: UUID?
    private let logger = Logger(subsystem: "local.cacalc.app", category: "AudioStartup")

    func activate(_ lease: UUID) throws {
        owner = lease
        let start = ContinuousClock.now
        defer {
            let elapsed = start.duration(to: .now)
            logger.info("Audio session activation: \(String(describing: elapsed), privacy: .public)")
        }
        let session = AVAudioSession.sharedInstance()
        // Measurement disables some input dynamics processing and can produce quiet audio.
        // Compare standard capture without adding a second software gain stage.
        try session.setCategory(.record, mode: .default)
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
    }

    // Transfer sole application ownership after blocking startup finishes.
    func startRecorder(at url: URL, lease: UUID) throws -> sending AVAudioRecorder {
        guard owner == lease else { throw CancellationError() }
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw NSError(domain: "local.cacalc.audio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Не удалось начать запись."])
        }
        return recorder
    }

    func finishRecorder(_ recorder: sending AVAudioRecorder) {
        recorder.stop()
    }

    func deactivate(_ lease: UUID) {
        guard owner == lease else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        owner = nil
    }
}
