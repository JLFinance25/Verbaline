import Foundation
import CoreAudio
import AudioToolbox

// MusicDucker
// -----------
// While you dictate with sound playing out loud on the Mac's own speakers, turns the Mac's volume down
// (to `level` × your volume: 50% by default, or 25%, 10% or mute from the settings menu) with a short fade, and back up when you're done. Music keeps
// playing; nothing is paused or muted. Headphones and AirPods are left alone: the mic can't hear them.
//
//     duck() -> Bool     call when recording starts; true if it turned the volume down
//     restore()          call when recording ends (or is cancelled); safe to call when nothing was ducked
//     recoverAfterCrash() call at launch: puts the volume back if the app quit while ducked
//
// If you change the volume yourself while it's ducked, restore() leaves your new volume alone.
// Main thread only.

final class MusicDucker {
    var level: Float = 0.5
    private(set) var isDucked = false
    private var original: Float = 0
    private var device: AudioDeviceID?   // the speakers we turned down (headphones plugged in later don't count)
    private var ducked: Float = 0
    private var fade: Timer?
    private let defaults = UserDefaults.standard
    private static let savedKey = "duckedFromVolume"

    /// Sound is going to the built-in speakers and some app is playing to them right now.
    static func speakersArePlaying() -> Bool {
        guard let out = defaultOutput(), AudioRecorder.defaultOutputIsBuiltIn() else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(out, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    @discardableResult
    func duck() -> Bool {
        guard !isDucked, Self.speakersArePlaying(), let out = Self.defaultOutput(), let now = Self.volume(out), now > 0.02
        else { return false }
        device = out
        original = now
        ducked = max(0, now * level)   // level 0 = mute (still playing, just silent)
        defaults.set(original, forKey: Self.savedKey)   // so a crash can't leave your music quiet
        isDucked = true
        ramp(to: ducked)
        return true
    }

    func restore() {
        guard isDucked else { return }
        isDucked = false
        defaults.removeObject(forKey: Self.savedKey)
        // You changed the volume yourself while talking: keep yours.
        if let now = Self.volume(device), abs(now - ducked) > 0.03, fade == nil { return }
        ramp(to: original)
    }

    /// At quit: no fade (the timer would never fire).
    func restoreNow() {
        guard isDucked else { return }
        isDucked = false
        fade?.invalidate()
        fade = nil
        defaults.removeObject(forKey: Self.savedKey)
        Self.setVolume(original, on: device)
    }

    func recoverAfterCrash() {
        guard let saved = defaults.object(forKey: Self.savedKey) as? Float else { return }
        defaults.removeObject(forKey: Self.savedKey)
        if let now = Self.volume(), now < saved { Self.setVolume(saved) }
    }

    /// ~150 ms fade so the change sounds deliberate, not like a glitch.
    private func ramp(to target: Float) {
        fade?.invalidate()
        let targetDevice = device
        guard let start = Self.volume(targetDevice) else { return }
        let steps = 6
        var step = 0
        fade = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] timer in
            step += 1
            let t = Float(step) / Float(steps)
            Self.setVolume(start + (target - start) * t, on: targetDevice)
            if step >= steps { timer.invalidate(); self?.fade = nil }
        }
        RunLoop.main.add(fade!, forMode: .common)
    }

    // MARK: Core Audio

    static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0
        else { return nil }
        return id
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    /// `device` nil = the current default output.
    static func volume(_ device: AudioDeviceID? = nil) -> Float? {
        guard let out = device ?? defaultOutput() else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(out, &volumeAddress, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    static func setVolume(_ value: Float, on device: AudioDeviceID? = nil) {
        guard let out = device ?? defaultOutput() else { return }
        var v = Float32(min(max(value, 0), 1))
        AudioObjectSetPropertyData(out, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}
