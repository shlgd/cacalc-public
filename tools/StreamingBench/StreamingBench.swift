import Foundation
import CoreML
import FluidAudio

@main struct StreamingBench {
    struct Policy { let name: String; let step: Double; let cooldown: Double; let poll: Double }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("MODEL_DIRECTORY AUDIO_WAV OUTPUT_JSON") }
        let directory = URL(fileURLWithPath: args[1])
        let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
        let start = Date()
        func load(_ name: String) throws -> MLModel { try MLModel(contentsOf: directory.appendingPathComponent(name + ".mlmodelc"),configuration:config) }
        let vocabulary = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("parakeet_vocab.json")))
        let models = try AsrModels(encoder:load("Encoder"),preprocessor:load("Preprocessor"),decoder:load("Decoder"),joint:load("JointDecisionv3"),configuration:config,vocabulary:Dictionary(uniqueKeysWithValues:vocabulary.compactMap { key,value in Int(key).map { ($0,value) } }),version:.v3)
        let manager = AsrManager(); try await manager.loadModels(models)
        print("Loaded \(Date().timeIntervalSince(start))s")
        func transcribe(_ samples: [Float]) async throws -> String {
            var state = try TdtDecoderState()
            return try await manager.transcribe(samples,decoderState:&state,language:.russian).text
        }
        _ = try await transcribe([Float](repeating:0,count:48000))
        let wave = try LiveWave.read(URL(fileURLWithPath:args[2]),from:0,finalized:true,limit:16_000*60)
        let audio = wave.samples
        guard audio.count == wave.totalSamples else { fatalError("Use a recording no longer than 60 seconds") }
        let duration = Double(audio.count)/16000
        let reference = try await transcribe(audio)
        print("Audio \(duration)s; full result: \(reference)")
        let policies = [Policy(name:"baseline",step:1,cooldown:0.8,poll:0.3),Policy(name:"500ms",step:0.5,cooldown:0,poll:0.1),Policy(name:"320ms",step:0.32,cooldown:0,poll:0.1)]
        var reports: [[String:Any]] = []
        // Virtual capture clock advances by actual inference time: new audio arrives during inference.
        // Same endpoint, finalization and 0.8s first-preview threshold as the application.
        for policy in policies + policies.reversed() {
            var t = 0.0, base = 0, previewThrough = -16000, previewFinished = -100.0
            var endpoint = LiveMealEndpoint(), events: [[String:Any]] = []
            var inference = 0.0, previous = "", committed: [String] = [], rewrites = 0
            while base < audio.count {
                let available = min(audio.count,Int(t*16000)), finished = available == audio.count
                let samples = Array(audio[base..<available])
                var range: Range<Int>?, final = false
                if let value = endpoint.next(samples,finished:finished) { range = value; final = true }
                else if !finished, let value = endpoint.previewRange,
                    base+value.upperBound-previewThrough >= Int(policy.step*16000), t-previewFinished >= policy.cooldown { range = value }
                if let range {
                    let began = Date(), at = t
                    let text = try await transcribe(Array(samples[range]))
                    let elapsed = Date().timeIntervalSince(began); inference += elapsed; t += elapsed
                    let old = previous.split(separator:" "), new = text.split(separator:" ")
                    let prefix = zip(old,new).prefix { $0 == $1 }.count
                    if prefix < old.count { rewrites += 1 }
                    events.append(["inputThrough":Double(base+range.upperBound)/16000,"started":at,"visibleAt":t,"inference":elapsed,"final":final,"text":text,"retractedWords":old.count-prefix])
                    previous = text
                    if final { committed.append(text); base += range.upperBound; endpoint = LiveMealEndpoint(); previous = ""; continue }
                    previewThrough = base+range.upperBound; previewFinished = t
                }
                if finished { break }
                let discard = endpoint.discardableSamples; base += discard; endpoint.discardPrefix(discard)
                t += policy.poll
            }
            let first = events.first { !($0["text"] as! String).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }?["visibleAt"] as? Double
            let result: [String:Any] = ["policy":policy.name,"firstText":first ?? -1,"calls":events.count,"inferenceSeconds":inference,"busyRatio":inference/duration,"rewriteUpdates":rewrites,"finalText":committed.joined(separator:" "),"events":events]
            reports.append(result)
            print("\(policy.name): first=\(first ?? -1) calls=\(events.count) inference=\(inference) rewrites=\(rewrites)")
        }
        let output: [String:Any] = ["audioSeconds":duration,"reference":reference,"mode":"Mac CPU warm virtual capture, real inference durations; no UI typing delay","runs":reports]
        try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[3]),options:.atomic)
        await manager.cleanup()
    }
}
