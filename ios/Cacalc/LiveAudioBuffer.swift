import Foundation

/// Keep the uncommitted phrase in memory and read only newly recorded samples.
/// The I/O chunk is bounded; speech is never split because it reached that bound.
struct LiveAudioBuffer: Sendable {
    private(set) var baseSample: Int
    private(set) var samples: [Float] = []
    private(set) var samplesRead = 0
    private(set) var reads = 0
    private(set) var peakSamples = 0
    var readOffset: Int { baseSample + samples.count }
    init(from sample: Int) { baseSample = sample }
    mutating func append(_ values: [Float]) {
        samples.append(contentsOf: values)
        samplesRead += values.count; reads += 1
        peakSamples = max(peakSamples, samples.count)
    }
    mutating func discard(through sample: Int) {
        let count = min(samples.count, max(0, sample - baseSample))
        samples.removeFirst(count); baseSample += count
    }
}

/// Early previews still arrive at one-second steps. For a long uninterrupted
/// phrase, grow the step with the phrase instead of decoding every old second
/// on every poll. Quiet/stop inference is independent of this preview budget.
struct LivePreviewCadence: Sendable {
    private(set) var nextSamples = 16_000
    func ready(samples: Int) -> Bool { samples >= nextSamples }
    mutating func completed(samples: Int) { nextSamples = samples + max(16_000, samples / 2) }
}
