import Foundation
import AVFoundation
import CoreAudio

// AirPods call mode (found on a real FaceTime test): when a meeting app opens the AirPods mic, they switch
// to 24 kHz while the tap's format still says 48 kHz. Trusting the format played Them at double speed, and Whisper
// wrote nonsense. Here notes start in music mode, "the meeting app" opens the mic 3 s later, and Them must still be
// heard word for word. Needs Bluetooth headphones as the output; skipped otherwise. Plays a clip on the output.
//   call_mode_test <speech.wav>     (build/test_audio/long.wav)

@main
enum CallModeTest {
    static var failed = 0
    static func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL")  \(name)"); if !ok { failed += 1 } }

    static func outputIsBluetooth() -> Bool {
        guard let dev = try? AudioHardwareSystem.shared.defaultOutputDevice,
              let transport = try? dev.transportType else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func main() async {
        guard outputIsBluetooth() else { print("SKIPPED (no Bluetooth headphones connected): call-mode test"); exit(0) }
        let clip = CommandLine.arguments[1]
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [clip]
        try! player.run()
        try? await Task.sleep(nanoseconds: 500_000_000)

        let rec = MeetingRecorder()
        try! rec.start(app: MeetingApp(name: "afplay", bundleID: nil, pids: [player.processIdentifier]))
        let mic = AVAudioEngine()
        var them: [Float] = []
        var opened = false
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 12 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            them += rec.takeNew().them
            if !opened, Date().timeIntervalSince(t0) > 3 {
                opened = true
                mic.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
                try? mic.start()
            }
        }
        rec.stop(); mic.stop(); player.terminate()
        check(rec.rateChanges >= 1, "recorder noticed the switch to call mode (\(rec.rateChanges))")

        let engine = WhisperEngine()
        let text = ((try? await engine.transcribe(samples: them, sampleRate: 16_000)) ?? "").lowercased()
        engine.unload()
        print("  heard: \(text)")
        // About 2 s around the switch itself are lost (the AirPods' own mode change cuts the sound, and the tap is
        // rebuilt); a real call switches as it connects, before anyone talks. So check words clear of that moment.
        check(text.contains("plan for this week"), "Them heard clearly before the switch ('plan for this week')")
        check(text.contains("appraisal"), "Them heard clearly after the switch ('appraisal')")
        exit(failed == 0 ? 0 : 1)
    }
}
