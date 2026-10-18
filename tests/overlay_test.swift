import Foundation

// overlay_test: the pill shows dots until your voice is heard, then bars; each dictation starts on dots.
// Exit 0 = all PASS.

@main struct OverlayTest {
    static var failed = 0
    static func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL")  \(name)"); if !ok { failed += 1 } }

    static func main() {
        let m = OverlayModel()
        check(!m.heardVoice, "a new pill starts on dots")
        for _ in 0..<20 { m.push(0.1) }
        check(!m.heardVoice, "room noise (well below voice level) stays on dots")
        m.push(0.6); m.push(0.05)
        check(!m.heardVoice, "a single click (one loud update) stays on dots")
        m.push(0.45); m.push(0.5)
        check(m.heardVoice, "two voice-level updates in a row switch to bars")
        for _ in 0..<20 { m.push(0.0) }
        check(m.heardVoice, "pausing mid-sentence keeps bars (no flicker back to dots)")
        check(m.levels.allSatisfy { $0 >= 0.05 && $0 <= 0.7 }, "bar heights stay between 5% and 70%")
        m.resetLevels()
        check(!m.heardVoice, "the next dictation starts on dots again")
        // Motion: voice starts abruptly (0 → 0.6), then stops. 60 frames a second for 1.2 s.
        let motion = WaveMotion()
        var t = 1000.0, prev = motion.step(t: t, level: 0, freeze: false), maxJump: CGFloat = 0
        var frameOfFullHeight: Int?, frameBackToDots: Int?
        for frame in 1...72 {
            t += 1.0 / 60
            let level: CGFloat = frame <= 36 ? 0.6 : 0
            let h = motion.step(t: t, level: level, freeze: false)
            for i in h.indices { maxJump = max(maxJump, abs(h[i] - prev[i])) }
            if frameOfFullHeight == nil, frame <= 36, h[5] > 6 { frameOfFullHeight = frame }   // middle bar clearly up
            if frame > 36, frameBackToDots == nil, h.allSatisfy({ $0 < 2.3 }) { frameBackToDots = frame - 36 }
            prev = h
        }
        check(maxJump <= 3.5, String(format: "no bar jumps more than 3.5 pt between frames (largest %.2f)", maxJump))
        check((frameOfFullHeight ?? 99) <= 15, "the middle bar rises clearly within a quarter second (\(frameOfFullHeight ?? -1) frames)")
        check((frameBackToDots ?? 99) <= 36, "bars settle back into dots within 0.6 s of silence (\(frameBackToDots ?? -1) frames)")
        let still = WaveMotion(); _ = still.step(t: 5, level: 0, freeze: false)
        check(still.step(t: 5.5, level: 0, freeze: false).allSatisfy { $0 == 2 }, "with no voice the shapes are still dots")
        print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
