import Foundation
import CoreAudio

// Meeting call probe: finds out which processes carry a real call, and whether MeetingRecorder hears it.
//   meeting_call_probe [minutes]     (default 10)
// Every 0.25 s it logs any change in which processes have their mic (in) or sound (out) running, with the app
// each belongs to. When MeetingDetector sees a meeting start, it starts MeetingRecorder on that app and logs the
// loudness of You and Them once a second until the meeting ends. Only levels are logged; no audio is kept.
// Used to find out what an iPhone call answered on the Mac looks like (docs/notetaker-iphone-calls.md).

@main
struct MeetingCallProbe {
    static func main() {
        let minutes = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 10 : 10
        let t0 = Date()
        func log(_ s: String) {
            print(String(format: "%7.2f  ", Date().timeIntervalSince(t0)) + s)
            fflush(stdout)
        }
        log("listening for \(Int(minutes)) min; output device: \(deviceName(kAudioHardwarePropertyDefaultOutputDevice)), input: \(deviceName(kAudioHardwarePropertyDefaultInputDevice))")

        var last: [pid_t: String] = [:]
        let detector = MeetingDetector()
        var recorder: MeetingRecorder?
        detector.onStart = { app in
            log("MEETING START: \(app.name) bundle=\(app.bundleID ?? "-") pids=\(app.pids)")
            let r = MeetingRecorder()
            do { try r.start(app: app); recorder = r; log("recording: mic=\(r.micName) hearingThem=\(r.hearingThem)") }
            catch { log("recorder failed: \(error.localizedDescription)") }
        }
        detector.onEnd = {
            log("MEETING END")
            recorder?.stop(); recorder = nil
        }
        detector.start()

        let poll = DispatchSource.makeTimerSource(queue: .main)
        poll.schedule(deadline: .now(), repeating: 0.25)
        var ticks = 0
        poll.setEventHandler {
            var now: [pid_t: String] = [:]
            for p in AudioProcess.all() where p.usingMic || p.playing {
                let owner = AudioProcess.executablePath(p.owner).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
                now[p.pid] = "\(p.executable) [\(p.bundleID ?? "-")] pid=\(p.pid) owner=\(owner)(\(p.owner)) in=\(p.usingMic ? 1 : 0) out=\(p.playing ? 1 : 0)"
            }
            for (pid, s) in now where last[pid] != s { log("+ " + s) }
            for (pid, s) in last where now[pid] == nil { log("- " + s) }
            last = now
            ticks += 1
            if ticks % 4 == 0, let r = recorder {
                let (you, them) = r.takeNew()
                log(String(format: "levels: you %.1f dB, them %.1f dB (%d samples)", db(you), db(them), them.count))
            }
        }
        poll.resume()
        RunLoop.main.run(until: Date().addingTimeInterval(minutes * 60))
        recorder?.stop()
        log("done")
    }

    static func db(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return -200 }
        let ms = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)
        return 10 * log10(max(ms, 1e-20))
    }

    static func deviceName(_ selector: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return "?" }
        addr.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?; size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() else { return "?" }
        return n as String
    }
}
