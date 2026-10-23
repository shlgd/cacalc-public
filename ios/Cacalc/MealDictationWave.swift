import SwiftUI
import UIKit
import Observation

/// iOS rendering of the RecordingHUDView in the user's SuperDictate.
/// The toolbar capsule stays fixed; only its contents animate.
struct MealDictationWave: View, @MainActor Animatable {
    @Environment(\.colorScheme) private var colorScheme
    let voice: VoiceSession
    let reduceMotion: Bool
    var preparing = false
    var reveal: Double = 1
    var closing = false
    var animatableData: Double {
        get { reveal }
        set { reveal = newValue }
    }
    var onLevel: (Double) -> Void = { _ in }
    @State private var clock = MealWaveClock()

    var body: some View {
        Canvas { context, size in
            let processing = clock.retainedProcessing
            let recording = clock.retainedRecording
            let audio = pow(clock.level, 0.82)
            let barCount = 17
            let barWidth = 4.0
            let gap = 3.0
            // Preserve SuperDictate's height/width proportions (2.05 pt bars).
            let visualScale = barWidth / 2.05
            let minHeight = 4.0 * visualScale
            let maxHeight = min(size.height * 0.90, 13.2 * visualScale)
            let center = Double(barCount - 1) / 2
            let totalWidth = Double(barCount) * barWidth + Double(barCount - 1) * gap
            for index in 0..<barCount {
                let i = Double(index)
                let normalized = (i - center) / center
                let envelope = pow(max(0, cos(normalized * .pi / 2)), 0.62)
                var activity = 0.0
                var conversion = 0.0
                if processing {
                    let resolve = reduceMotion ? 1 : min(1, clock.processingAge / 0.20)
                    let loop = reduceMotion ? 0 : max(0, clock.processingAge - 0.20)
                    let progress = i / Double(barCount - 1)
                    conversion = smoothstep(progress - 0.34, progress + 0.08, resolve)
                    let front = max(0, 1 - abs(resolve - progress) / 0.18) * (1 - smoothstep(0.82, 1, resolve))
                    let head = 1 - (loop * 3.8).truncatingRemainder(dividingBy: 1)
                    let pulse = max(0, 1 - abs(head - progress) / 0.24)
                    let wave = (sin(loop * 6.2 + i * 0.56) + 1) / 2
                    let counter = (sin(loop * 2.8 + i * 1.27) + 1) / 2
                    let lift = front * (0.48 + 0.30 * envelope)
                    let blue = conversion * (0.14 * wave + 0.08 * counter * envelope + 0.34 * pulse)
                    let red = (1 - conversion) * (0.16 + 0.12 * envelope)
                    activity = min(0.94, 0.15 + 0.24 * envelope + red + blue + lift)
                } else if recording || voice.phase == .paused {
                    let traveling = (sin(clock.phase * 1.02 - normalized * 2.85) + 1) / 2
                    // Preserve individual variation in the compact voice indicator.
                    let counter = (sin(clock.phase * 1.57 + i * 1.17) + 1) / 2
                    let variance = (sin(clock.phase * 0.23 + i * 2.11) + 1) / 2
                    let gain = 0.72 + 0.28 * variance
                    let idle = 0.14 + 0.075 * traveling + 0.055 * counter * envelope
                    let bias = 0.22 + 0.78 * envelope
                    let motion = audio * bias * (0.18 + 0.42 * traveling + 0.14 * counter) * gain
                    activity = min(0.88, idle + motion)
                }
                let color: Color = colorScheme == .dark ? .white : .black
                let height = processing
                    ? min(size.height - 12, 7 + 34 * activity)
                    : minHeight + (maxHeight - minHeight) * activity
                // One horizontal progress keeps every gap equal throughout the reveal.
                let p = reduceMotion ? (reveal > 0.5 ? 1.0 : 0.0)
                    : min(1, max(0, reveal))
                guard p > 0 else { continue }
                let t = p - 1
                let spread = 1 + 2.1 * t * t * t + 1.1 * t * t
                let settledX = (size.width - totalWidth) / 2 + i * (barWidth + gap)
                let originX = (size.width - barWidth) / 2
                let drawnHeight = height
                let rect = CGRect(x: originX + (settledX - originX) * spread,
                                  y: (size.height - drawnHeight) / 2,
                                  width: barWidth, height: drawnHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
            }
        }
        .accessibilityHidden(true)
        .onAppear { clock.update(voice: voice, reduceMotion: reduceMotion, preparing: preparing, closing: closing, onLevel: onLevel) }
        .onChange(of: voice.phase) { _, _ in clock.update(voice: voice, reduceMotion: reduceMotion, preparing: preparing, closing: closing, onLevel: onLevel) }
        .onChange(of: preparing) { _, _ in clock.update(voice: voice, reduceMotion: reduceMotion, preparing: preparing, closing: closing, onLevel: onLevel) }
        .onChange(of: closing) { _, _ in clock.update(voice: voice, reduceMotion: reduceMotion, preparing: preparing, closing: closing, onLevel: onLevel) }
        .onChange(of: reduceMotion) { _, _ in clock.update(voice: voice, reduceMotion: reduceMotion, preparing: preparing, closing: closing, onLevel: onLevel) }
        .onDisappear { clock.stop() }
    }
    private func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }
}

/// Display-linked updates stay local to the waveform. Speech breathing updates at 30 Hz.
@MainActor @Observable final class MealWaveClock: NSObject {
    var phase = 0.0
    var level = 0.0
    var processingAge = 0.0
    var retainedProcessing = false
    var retainedRecording = false
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private weak var voice: VoiceSession?
    @ObservationIgnored private var reduceMotion = false
    @ObservationIgnored private var startupAge = 0.0
    @ObservationIgnored private var closingTail: Double?
    @ObservationIgnored private var previousTime = 0.0
    @ObservationIgnored private var lastBreath = 0.0
    @ObservationIgnored private var onLevel: (Double) -> Void = { _ in }

    func update(voice: VoiceSession, reduceMotion: Bool, preparing: Bool, closing: Bool, onLevel: @escaping (Double) -> Void) {
        self.voice = voice; self.reduceMotion = reduceMotion; self.onLevel = onLevel
        // Keep the last audio amplitude, but continue phase motion through the exit.
        // The tail is longer than the 240 ms exit and cannot be restarted by phase updates.
        if closing {
            if closingTail == nil { closingTail = 0.30 }
            return
        }
        closingTail = nil
        guard preparing || voice.phase == .requesting || voice.phase == .recording || voice.processing else {
            stop()
            onLevel(0)
            return
        }
        retainedProcessing = voice.processing
        retainedRecording = !voice.processing
        processingAge = 0
        guard link == nil else { return }
        previousTime = 0; lastBreath = 0; startupAge = 0
        if !reduceMotion { level = max(level, 0.22) }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: reduceMotion ? 10 : 30,
                                                       maximum: reduceMotion ? 10 : 120,
                                                       preferred: reduceMotion ? 10 : 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) {
        guard let voice else { stop(); return }
        let now = link.timestamp
        let dt = previousTime == 0 ? 1.0 / 60 : min(0.05, max(0, now - previousTime))
        previousTime = now
        if let remaining = closingTail {
            if remaining <= 0 { stop(); return }
            closingTail = remaining - dt
            if !reduceMotion { phase += dt * (16.96 + 10.08 * level) }
            if retainedProcessing { processingAge += dt }
            return
        }
        // Brief visual lead-in bridges microphone startup; never modifies recorded audio.
        startupAge += dt
        let leadIn = reduceMotion ? 0 : 0.22 * max(0, 1 - startupAge / 0.30)
        let target = max(voice.inputLevel(), leadIn)
        level += (target - level) * (1 - exp(-dt * (target > level ? 24 : 10)))
        if !reduceMotion { phase += dt * (16.96 + 10.08 * level) }
        if voice.processing { processingAge += dt }
        if now - lastBreath >= 1.0 / 30 {
            lastBreath = now
            onLevel(voice.phase == .recording ? level : 0)
        }
    }
    func stop() { link?.invalidate(); link = nil }
}
