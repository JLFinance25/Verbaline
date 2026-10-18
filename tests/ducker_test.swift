import Foundation

// ducker_test: MusicDucker turns speaker volume down and back, respects your own changes, and recovers
// after a crash. Changes the real system volume for ~3 s and always puts it back. Needs something playing
// on the built-in speakers (the suite plays a quiet clip). Exit 0 = all PASS.

@main struct DuckerTest {
    static var failed = 0
    static func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL")  \(name)"); if !ok { failed += 1 } }
    static func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    static func near(_ a: Float?, _ b: Float) -> Bool { a.map { abs($0 - b) < 0.02 } ?? false }

    static func main() {
        guard let start = MusicDucker.volume() else { print("FAIL  no output volume"); exit(1) }
        defer { MusicDucker.setVolume(start) }
        guard MusicDucker.speakersArePlaying() else { print("SKIP  nothing playing on the built-in speakers"); exit(0) }
        UserDefaults.standard.removeObject(forKey: "duckedFromVolume")

        let d = MusicDucker()
        check(d.duck(), "ducks when the speakers are playing")
        wait(0.3)
        check(near(MusicDucker.volume(), start * 0.5), String(format: "volume goes to half (%.2f → %.2f)", start, MusicDucker.volume() ?? -1))
        check(!d.duck(), "a second duck() while ducked does nothing")
        d.restore(); wait(0.3)
        check(near(MusicDucker.volume(), start), "restore() brings it back")
        d.restore(); wait(0.1)
        check(near(MusicDucker.volume(), start), "an extra restore() changes nothing")

        // You change the volume yourself while it's ducked: yours wins.
        d.duck(); wait(0.3)
        MusicDucker.setVolume(0.2); wait(0.05)
        d.restore(); wait(0.3)
        check(near(MusicDucker.volume(), 0.2), "your own volume change during dictation is kept")
        MusicDucker.setVolume(start); wait(0.05)

        // Very short dictation: restore() while the fade down is still running.
        d.duck(); wait(0.03); d.restore(); wait(0.3)
        check(near(MusicDucker.volume(), start), "restore during the fade still ends at your volume")

        // Crash while ducked: the next launch puts it back.
        let crashed = MusicDucker()
        crashed.duck(); wait(0.3)
        MusicDucker().recoverAfterCrash()
        check(near(MusicDucker.volume(), start), "recoverAfterCrash() restores the volume")
        check(UserDefaults.standard.object(forKey: "duckedFromVolume") == nil, "crash marker cleared")

        // restoreNow() (at quit) works without the run loop.
        let quitting = MusicDucker()
        quitting.duck(); wait(0.3)
        quitting.restoreNow()
        check(near(MusicDucker.volume(), start), "restoreNow() at quit restores immediately")

        print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
