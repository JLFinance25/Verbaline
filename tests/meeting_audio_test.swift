import Foundation
import AVFoundation
import CoreAudio

// Tests for src/MeetingAudio.swift.
//   meeting_audio_test            all tests (plays two tones quietly on the speakers, opens the mic)
//   meeting_audio_test --quick    only the tests that need no sound or mic
//   meeting_audio_test --hold-mic SECONDS   helper mode: keep the mic open that long (used by the detector test)
//
// 1. Lining up: StreamAligner pads a late or paused stream with silence and returns equal lengths.
// 2. Grouping: helper processes belong to their app (path rule, and Core Audio's live list).
// 3. Detector timing with a fake clock: 3 s to start, 5 s to end, short blips ignored.
// 4. Per-app tap: two afplay processes play different tones; tapping one records its tone and not the other's.
// 5. Detector for real: a helper process opens the mic; onStart and onEnd fire on time with the right process.

@main
struct MeetingAudioTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "PASS  \(what)" : "FAIL  \(what)")
        if !ok { failures += 1 }
    }

    static func main() {
        let args = CommandLine.arguments
        if args.count > 2, args[1] == "--hold-mic", let secs = Double(args[2]) { holdMic(secs) }
        alignerTests()
        groupingTests()
        detectorClockTests()
        if !args.contains("--quick") {
            tapTest()
            followTest()
            recoveryTest()
            detectorLiveTest()
        }
        print(failures == 0 ? "all meeting audio tests passed" : "\(failures) meeting audio test(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: 1. Aligner

    static func alignerTests() {
        var a = StreamAligner(start: 100, rate: 1000)
        a.push([Float](repeating: 1, count: 100), to: .you, endingAt: 100.1)       // you: 0–0.1 s
        a.push([Float](repeating: 2, count: 100), to: .them, endingAt: 100.5)      // them started 0.4 s late
        check(a.position(.them) == 500, "aligner: a late stream is padded to where it should be (\(a.position(.them)))")
        a.push([Float](repeating: 1, count: 400), to: .you, endingAt: 100.5)
        let t = a.take(now: 100.5)
        check(t.you.count == 500 && t.them.count == 500, "aligner: take returns equal lengths (\(t.you.count)/\(t.them.count))")
        check(t.them.prefix(400).allSatisfy { $0 == 0 } && t.them[400] == 2, "aligner: the late stream's sound lands at its real time")
        // Small jitter doesn't insert silence.
        a.push([Float](repeating: 1, count: 100), to: .you, endingAt: 100.65)
        check(a.position(.you) == 600, "aligner: 50 ms of jitter adds no silence (\(a.position(.you)))")
        // A stream that stops delivering doesn't hold the other back for more than a second.
        a.push([Float](repeating: 1, count: 2400), to: .you, endingAt: 103.0)
        let t2 = a.take(now: 103.0)
        check(t2.you.count == 1500, "aligner: a silent stream is filled in, holding the other back at most 1 s (\(t2.you.count) out)")
    }

    // MARK: 2. Grouping

    static func groupingTests() {
        let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        check(AudioProcess.appBundlePath(forExecutable: chrome) == "/Applications/Google Chrome.app", "grouping: Chrome helper path belongs to Google Chrome.app")
        check(AudioProcess.appBundlePath(forExecutable: "/usr/libexec/avconferenced") == nil, "grouping: a daemon has no app folder")
        // Live: every process's owner is known, and no app list ever includes this test process.
        let all = AudioProcess.all()
        check(!all.isEmpty, "grouping: Core Audio lists \(all.count) processes")
        let apps = MeetingDetector.apps(from: all, usingMicOnly: false)
        check(!apps.contains { $0.pids.contains(getpid()) }, "grouping: Verbaline (this process) is never part of an app")
        if let chromeApp = apps.first(where: { $0.bundleID == "com.google.Chrome" }) {
            check(chromeApp.name == "Google Chrome" && chromeApp.pids.count > 1,
                  "grouping: Chrome's helpers are grouped under \"\(chromeApp.name)\" (\(chromeApp.pids.count) processes)")
        }
        let fake = [AudioProcess(object: 1, pid: 999_001, owner: 999_000, bundleID: "x.helper", executable: "x", usingMic: true, playing: false),
                    AudioProcess(object: 2, pid: 999_002, owner: 999_000, bundleID: "x.helper", executable: "x", usingMic: false, playing: true),
                    AudioProcess(object: 3, pid: 999_003, owner: 999_003, bundleID: "music", executable: "x", usingMic: false, playing: true),
                    AudioProcess(object: 4, pid: 999_004, owner: 999_004, bundleID: "com.apple.corespeechd_system", executable: "x", usingMic: true, playing: false),
                    AudioProcess(object: 5, pid: 999_005, owner: 999_005, bundleID: nil, executable: "historicalaudiod", usingMic: true, playing: false)]
        let found = MeetingDetector.apps(from: fake, usingMicOnly: true)
        check(found.count == 1 && found[0].pids == [999_001, 999_002],
              "grouping: the mic user's app includes its sound-playing helper; music, Siri and the mic-usage log are left out (\(found.map(\.pids)))")
    }

    // MARK: 3. Detector with a fake clock

    static func detectorClockTests() {
        let d = MeetingDetector()
        var started: [(MeetingApp, Double)] = [], ended: [Double] = []
        var now = 0.0
        d.onStart = { started.append(($0, now)) }
        d.onEnd = { ended.append(now) }
        let zoom = MeetingApp(name: "zoom.us", bundleID: "us.zoom.xos", pids: [getpid() + 100_000])
        func run(_ apps: [MeetingApp], for secs: Double) {
            let end = now + secs
            while now < end - 1e-9 { now += 0.5; d.step(apps: apps, now: now) }
        }
        run([], for: 2)
        run([zoom], for: 2)     // a 2 s blip: not a meeting
        run([], for: 2)
        check(started.isEmpty, "detector: 2 s of mic use is not a meeting")
        run([zoom], for: 10)
        check(started.count == 1 && abs(started[0].1 - 9.5) < 0.01, "detector: start fires 3 s after the mic opens (at \(started.first?.1 ?? -1), expected 9.5)")
        run([], for: 4)
        run([zoom], for: 1)     // the app let go briefly (muting, switching mic)
        run([], for: 4.5)
        check(ended.isEmpty, "detector: short gaps in mic use don't end the meeting")
        run([], for: 1)
        check(ended.count == 1 && abs(ended[0] - 26) < 0.01, "detector: end fires 5 s after the mic is let go (at \(ended.first ?? -1), expected 26)")

        // The meeting app leaves while another app (Voice Memos) keeps the mic: the meeting still ends,
        // and Voice Memos, already on the mic during the meeting, doesn't start a new one.
        let memos = MeetingApp(name: "Voice Memos", bundleID: "com.apple.VoiceMemos", pids: [getpid() + 100_001])
        started.removeAll(); ended.removeAll()
        run([zoom], for: 4)                    // first seen at 27 → meeting starts at 30
        run([zoom, memos], for: 4)             // 31–34.5
        run([memos], for: 6)                   // zoom last seen at 34.5 → end at 39.5
        check(started.count == 1 && started[0].0 == zoom, "detector: the meeting app is the one that held the mic first")
        check(ended.count == 1 && abs(ended[0] - 39.5) < 0.01, "detector: the meeting ends when its app lets go, even with another app on the mic (at \(ended.first ?? -1), expected 39.5)")
        run([memos], for: 10)
        check(started.count == 1, "detector: an app that was already on the mic during the meeting doesn't start a new one")
        run([], for: 1)
        run([memos], for: 4)                   // Voice Memos comes back on its own: that's new mic use
        check(started.count == 2 && started.last?.0 == memos, "detector: once it lets go and comes back, it counts again")
    }

    // MARK: 4. Per-app tap

    static func tapTest() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verbaline-meeting-audio-test")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let low = dir.appendingPathComponent("tone440.wav"), high = dir.appendingPathComponent("tone1500.wav")
        writeTone(440, seconds: 9, to: low); writeTone(1500, seconds: 9, to: high)

        // "The meeting app" plays 440 Hz; "the music app" plays 1500 Hz at the same time.
        let meeting = launch("/usr/bin/afplay", ["-v", "0.15", low.path])
        let music = launch("/usr/bin/afplay", ["-v", "0.15", high.path])
        defer { meeting.terminate(); music.terminate() }
        // Wait until Core Audio sees both playing.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let playing = Set(AudioProcess.all().filter(\.playing).map(\.pid))
            if playing.contains(meeting.processIdentifier) && playing.contains(music.processIdentifier) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        for (name, target, wanted, unwanted) in [("meeting app", meeting, 440.0, 1500.0), ("music app", music, 1500.0, 440.0)] {
            let recorder = MeetingRecorder()
            recorder.followsNewProcesses = false   // both afplays belong to the same parent here; see followTest
            do {
                try recorder.start(app: MeetingApp(name: name, bundleID: nil, pids: [target.processIdentifier]))
            } catch {
                check(false, "tap: recording \(name) started (\(error.localizedDescription))")
                continue
            }
            var you: [Float] = [], them: [Float] = []
            var lengthsMatch = true
            for _ in 0..<6 {
                Thread.sleep(forTimeInterval: 0.5)
                let new = recorder.takeNew()
                lengthsMatch = lengthsMatch && new.you.count == new.them.count
                you += new.you; them += new.them
            }
            recorder.stop()
            let secs = Double(them.count) / 16_000
            check(lengthsMatch && secs > 2.0, "tap(\(name)): you and them come back the same length (\(String(format: "%.1f", secs)) s, mic: \(recorder.micName))")
            let body = Array(them.dropFirst(8_000))   // skip the first half second
            let w = db(goertzel(body, wanted)), u = db(goertzel(body, unwanted))
            check(w > -45, "tap(\(name)): its own \(Int(wanted)) Hz tone is recorded (\(String(format: "%.1f", w)) dB)")
            check(w - u > 30, "tap(\(name)): the other app's \(Int(unwanted)) Hz tone is not (\(String(format: "%.1f", u)) dB, \(String(format: "%.0f", w - u)) dB lower)")
            let micRMS = db(rms(you))
            check(micRMS > -100, "tap(\(name)): the mic delivered sound too (\(String(format: "%.1f", micRMS)) dB)")
        }
    }

    /// A sound process the app starts after recording began is picked up (the tap is rebuilt within ~2 s).
    /// Both afplays are children of this test, so to the recorder they're two processes of one app.
    static func followTest() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verbaline-meeting-audio-test")
        let first = launch("/usr/bin/afplay", ["-v", "0.15", dir.appendingPathComponent("tone440.wav").path])
        defer { first.terminate() }
        Thread.sleep(forTimeInterval: 0.5)
        let recorder = MeetingRecorder()
        do { try recorder.start(app: MeetingApp(name: "tones", bundleID: nil, pids: [first.processIdentifier])) } catch {
            check(false, "follow: recording started (\(error.localizedDescription))"); return
        }
        Thread.sleep(forTimeInterval: 0.5)
        let before = recorder.takeNew().them
        let second = launch("/usr/bin/afplay", ["-v", "0.15", dir.appendingPathComponent("tone1500.wav").path])
        defer { second.terminate() }
        Thread.sleep(forTimeInterval: 3.5)
        let after = recorder.takeNew().them
        recorder.stop()
        let late = Array(after.suffix(16_000))   // the last second
        check(db(goertzel(before, 1500)) < -80, "follow: before the new process starts, its tone isn't there")
        check(recorder.restarts == 1 && db(goertzel(late, 1500)) > -45 && db(goertzel(late, 440)) > -45,
              "follow: a sound process the app starts later is recorded too (restarts: \(recorder.restarts), \(String(format: "%.1f", db(goertzel(late, 1500)))) dB)")
    }

    /// If rebuilding the tap fails once, the recorder says so and keeps retrying until Them is back.
    static func recoveryTest() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verbaline-meeting-audio-test")
        let first = launch("/usr/bin/afplay", ["-v", "0.15", dir.appendingPathComponent("tone440.wav").path])
        defer { first.terminate() }
        Thread.sleep(forTimeInterval: 0.5)
        let recorder = MeetingRecorder()
        var changes: [Bool] = []
        recorder.onHearingThemChanged = { changes.append($0) }
        do { try recorder.start(app: MeetingApp(name: "tones", bundleID: nil, pids: [first.processIdentifier])) } catch {
            check(false, "recovery: recording started (\(error.localizedDescription))"); return
        }
        check(recorder.hearingThem, "recovery: hearing Them after start")
        recorder.testFailTapStarts = 1          // the rebuild below fails once
        let second = launch("/usr/bin/afplay", ["-v", "0.15", dir.appendingPathComponent("tone1500.wav").path])
        defer { second.terminate() }
        spin(until: { changes.count >= 3 }, max: 7)
        Thread.sleep(forTimeInterval: 0.5)
        let them = recorder.takeNew().them
        recorder.stop()
        check(changes == [true, false, true], "recovery: a failed rebuild is reported, then the retry brings Them back (\(changes))")
        let late = Array(them.suffix(8_000))
        check(db(goertzel(late, 440)) > -45 && db(goertzel(late, 1500)) > -45,
              "recovery: after the retry both processes are heard (\(String(format: "%.1f", db(goertzel(late, 440)))) / \(String(format: "%.1f", db(goertzel(late, 1500)))) dB)")
    }

    // MARK: 5. Detector, live

    static func detectorLiveTest() {
        let d = MeetingDetector()
        var startedAt: TimeInterval?, endedAt: TimeInterval?, app: MeetingApp?
        d.onStart = { app = $0; startedAt = ProcessInfo.processInfo.systemUptime }
        d.onEnd = { endedAt = ProcessInfo.processInfo.systemUptime }
        // The detector must not already see a meeting (another app on the mic would spoil the timing).
        let busy = MeetingDetector.appsUsingMic()
        if !busy.isEmpty {
            check(false, "detector(live): mic is free before the test (in use by \(busy.map(\.name)))")
            return
        }
        d.start()

        // A 1.5 s blip first: must not start a meeting.
        let blip = launch(CommandLine.arguments[0], ["--hold-mic", "1.5"])
        spin(until: { !blip.isRunning }, max: 6)
        spin(until: { false }, max: 3)
        check(startedAt == nil, "detector(live): a 1.5 s mic blip is not a meeting")

        let helper = launch(CommandLine.arguments[0], ["--hold-mic", "8"])
        var micOnAt: TimeInterval?
        spin(until: {
            if micOnAt == nil, MeetingDetector.appsUsingMic().contains(where: { $0.pids.contains(helper.processIdentifier) }) {
                micOnAt = ProcessInfo.processInfo.systemUptime
            }
            return startedAt != nil
        }, max: 8)
        if let micOnAt, let startedAt {
            let delay = startedAt - micOnAt
            check(delay > 2.4 && delay < 4.2, "detector(live): onStart fired \(String(format: "%.1f", delay)) s after the helper opened the mic (expected ~3)")
        } else {
            check(false, "detector(live): onStart fired (mic seen: \(micOnAt != nil))")
        }
        check(app?.pids.contains(helper.processIdentifier) == true, "detector(live): the meeting app includes the helper process (\(app?.name ?? "none"))")
        spin(until: { !helper.isRunning }, max: 10)
        let goneAt = ProcessInfo.processInfo.systemUptime
        spin(until: { endedAt != nil }, max: 9)
        if let endedAt {
            let delay = endedAt - goneAt
            check(delay > 4.4 && delay < 6.2, "detector(live): onEnd fired \(String(format: "%.1f", delay)) s after the mic was let go (expected ~5)")
        } else {
            check(false, "detector(live): onEnd fired")
        }
        d.stop()
    }

    // MARK: Helpers

    /// Helper mode: open the mic like a meeting app would, hold it, exit.
    static func holdMic(_ secs: Double) -> Never {
        guard let device = AVCaptureDevice.default(for: .audio), let mic = MicCapture(device: device) else {
            print("no mic"); exit(2)
        }
        mic.onSamples = { _ in }
        mic.start()
        Thread.sleep(forTimeInterval: secs)
        mic.stop()
        exit(0)
    }

    static func launch(_ path: String, _ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        return p
    }

    /// Runs the main run loop (so the detector's timer fires) until the condition holds or time runs out.
    static func spin(until done: () -> Bool, max secs: Double) {
        let end = Date().addingTimeInterval(secs)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func writeTone(_ hz: Double, seconds: Double, to url: URL) {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let n = AVAudioFrameCount(48_000 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        for i in 0..<Int(n) { buf.floatChannelData![0][i] = 0.5 * Float(sin(2 * .pi * hz * Double(i) / 48_000)) }
        try? FileManager.default.removeItem(at: url)
        let file = try! AVAudioFile(forWriting: url, settings: fmt.settings)
        try! file.write(from: buf)
    }

    /// Amplitude of one frequency in 16 kHz audio (a sine of amplitude A gives about A/√2, like RMS).
    static func goertzel(_ x: [Float], _ hz: Double) -> Double {
        guard !x.isEmpty else { return 0 }
        let k = 2 * cos(2 * .pi * hz / 16_000)
        var s1 = 0.0, s2 = 0.0
        for v in x { let s = Double(v) + k * s1 - s2; s2 = s1; s1 = s }
        let power = s1 * s1 + s2 * s2 - k * s1 * s2
        return (2 * power).squareRoot() / Double(x.count) / 2.0.squareRoot()
    }

    static func rms(_ x: [Float]) -> Double {
        x.isEmpty ? 0 : (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    static func db(_ v: Double) -> Double { 20 * log10(max(v, 1e-9)) }
}
