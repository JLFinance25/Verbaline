import Foundation
import AVFoundation

// music_gate_test: with music playing out loud, the stricter gate must drop the music and keep the voice.
//   music_gate_test <leakDir> <voice.wav> [<voice2.wav> ...]
// leakDir holds mic recordings of speaker audio made with `Verbaline --leaktest` (*.json.wav).
// For each leak recording: (1) the leak alone must produce no text; (2) each voice clip, mixed on top at a
// normal and a soft speaking level, must come out with its words and none of the music's.
// MGT_ABS / MGT_CAP override the music gate tuning to try values. Exit 0 = all PASS.

func load(_ path: String) -> [Float] {
    let f = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: f.processingFormat.sampleRate, channels: 1, interleaved: false)!
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length))!
    try! f.read(into: b)
    return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
}
func rmsDB(_ x: [Float]) -> Float { 20 * log10(max((x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))).squareRoot(), 1e-9)) }
/// Scales `voice` so its loud parts (top half of 20 ms frames) sit at `db`, and adds it to `bed` at 0.8 s.
func mix(_ bed: [Float], _ voice: [Float], atDB db: Float) -> [Float] {
    let frames = stride(from: 0, to: voice.count - 320, by: 320).map { rmsDB(Array(voice[$0..<$0 + 320])) }.sorted()
    let loud = frames[frames.count / 2]
    let gain = powf(10, (db - loud) / 20)
    var out = bed
    let start = 12_800
    if out.count < start + voice.count { out += [Float](repeating: 0, count: start + voice.count - out.count) }
    for i in 0..<voice.count { out[start + i] += voice[i] * gain }
    return out
}
func words(_ s: String) -> Set<String> {
    Set(s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 2 })
}

@main struct MusicGateTest {
    static var failed = 0
    static let reportOnly = ProcessInfo.processInfo.environment["MGT_REPORT_ONLY"] == "1"
    static func check(_ ok: Bool, _ name: String) {
        print("\(ok ? "PASS" : (reportOnly ? "leak" : "FAIL"))  \(name)")
        if !ok && !reportOnly { failed += 1 }
    }

    static func main() async {
        let env = ProcessInfo.processInfo.environment
        if let v = env["MGT_ABS"].flatMap(Float.init) { MusicGateTuning.absMinDB = v }
        if let v = env["MGT_CAP"].flatMap(Float.init) { MusicGateTuning.capBelowSpeechDB = v }
        print("music gate: absMinDB \(MusicGateTuning.absMinDB), capBelowSpeechDB \(MusicGateTuning.capBelowSpeechDB)")
        let args = CommandLine.arguments
        let leaks = try! FileManager.default.contentsOfDirectory(atPath: args[1]).filter { $0.hasSuffix(".json.wav") }.sorted()
        let engine = WhisperEngine()
        func stt(_ x: [Float], music: Bool) async -> String {
            let g = music ? SpeechGate.process(x, sampleRate: 16_000, params: SpeechGate.musicParams) : SpeechGate.process(x)
            guard g.hasSpeech else { return "" }
            return (try? await engine.transcribe(samples: g.samples, sampleRate: 16_000)) ?? "ERROR"
        }
        // Reference text for each voice clip, transcribed clean.
        var refs: [(String, [Float], Set<String>)] = []
        for v in args.dropFirst(2) {
            let x = load(v)
            refs.append(((v as NSString).lastPathComponent, x, words(await stt(x, music: false))))
        }
        for leakName in leaks {
            let bed = load(args[1] + "/" + leakName)
            let leakAlone = await stt(bed, music: true)
            check(leakAlone.isEmpty, "\(leakName) alone (\(String(format: "%.0f", rmsDB(bed))) dB): no text — got \"\(leakAlone)\"")
            let leakWords = words(await stt(bed, music: false))
            for (name, voice, ref) in refs {
                for (label, db) in [("normal voice", Float(-30)), ("soft voice", Float(-42))] {
                    let text = await stt(mix(bed, voice, atDB: db), music: true)
                    let got = words(text)
                    let kept = Double(got.intersection(ref).count) / Double(max(ref.count, 1))
                    let intruders = got.subtracting(ref).intersection(leakWords)
                    check(kept >= 0.8 && intruders.isEmpty,
                          "\(leakName) + \(name) (\(label)): \(Int(kept * 100))% of words kept, music words: \(intruders.sorted()) — \"\(text)\"")
                }
            }
        }
        engine.unload()
        print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
