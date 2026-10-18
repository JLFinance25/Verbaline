import Foundation
import AVFoundation

// engine_test: WhisperEngine's warm-up must never block, break or slow a dictation that follows it.
//   engine_test <speech.wav>     (16 kHz mono)
// Exit code: 0 = all PASS.

@main struct EngineTest {
    static var failed = 0
    static func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL")  \(name)"); if !ok { failed += 1 } }

    static func main() async {
        let path = CommandLine.arguments[1]
        let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try! file.read(into: buf)
        let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))

        let engine = WhisperEngine()
        // 1. Transcribing before prepare() waits for the model instead of failing.
        let first = try? await engine.transcribe(samples: samples, sampleRate: 16_000)
        check((first ?? "").count > 10, "transcribe before prepare() loads the model and works")
        let baseline = (first ?? "")

        // 2. Warm-up immediately followed by a dictation: same text, no hang.
        engine.prewarm()
        let t0 = Date()
        let second = try? await engine.transcribe(samples: samples, sampleRate: 16_000)
        let secs = Date().timeIntervalSince(t0)
        check(second == baseline, "dictation right after warm-up gives the same text")
        check(secs < 3, String(format: "dictation right after warm-up finishes quickly (%.2f s)", secs))

        // 3. A second warm-up within 20 s is skipped (no pile-up when you dictate back to back).
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let w1 = engine.lastPrewarmSeconds
        engine.prewarm()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        check(w1 != nil && engine.lastPrewarmSeconds == w1, "repeat warm-up within 20 s is skipped")

        // 4. Ten warm-ups and dictations fired at once all finish with the right text.
        let results = await withTaskGroup(of: String?.self) { group -> [String?] in
            for _ in 0..<10 {
                group.addTask { engine.prewarm(); return try? await engine.transcribe(samples: samples, sampleRate: 16_000) }
            }
            var out: [String?] = []
            for await r in group { out.append(r) }
            return out
        }
        check(results.allSatisfy { $0 == baseline }, "10 overlapping dictations all return the same text")

        // 5. Wrong sample rate is refused, not mangled.
        let bad = try? await engine.transcribe(samples: samples, sampleRate: 44_100)
        check(bad == nil, "44.1 kHz audio is refused")

        engine.unload()
        print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
