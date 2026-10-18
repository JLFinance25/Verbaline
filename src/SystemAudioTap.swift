import Foundation
import CoreAudio
import AVFoundation

// SystemAudioTap
// --------------
// Records what the Mac is playing (every app except Verbaline itself), as 16 kHz mono, without changing
// what you hear. Used as the echo canceller's reference: "this is the sound that's leaking into the mic".
// Given a list of processes, it records only those (the meeting notetaker taps just the meeting app).
// Needs the "System Audio Recording" permission (macOS asks the first time).
//
//     init(processes:)   nil = everything except Verbaline; a pid list = only those processes
//     start() throws     begin capturing (call when dictation starts)
//     stop() -> [Float]  end capturing, return everything since start() at 16 kHz mono
//     takeNew()          while running: the samples since the last call, at the tap's own rate (`sampleRate`)
//     startedAt          system uptime of the first captured buffer (for lining up with the mic)
//
// Built on Core Audio process taps (macOS 14.2+), the approach proven in the old CallTap spike.

final class SystemAudioTap {
    enum TapError: LocalizedError {
        case create(OSStatus), format(OSStatus), aggregate(OSStatus), ioProc(OSStatus), start(OSStatus)
        var errorDescription: String? {
            switch self {
            case .create(let e): return "Couldn't create the system audio tap (\(e))"
            case .format(let e): return "Couldn't read the tap's format (\(e))"
            case .aggregate(let e): return "Couldn't create the tap device (\(e))"
            case .ioProc(let e): return "Couldn't attach to the tap (\(e))"
            case .start(let e): return "System audio recording didn't start (\(e)) — check System Audio Recording permission"
            }
        }
    }

    /// nil = every process except Verbaline; otherwise only these.
    let processes: [pid_t]?
    init(processes: [pid_t]? = nil) { self.processes = processes }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let lock = NSLock()
    private var native: [Float] = []           // mono, at the tap's own rate
    private var _startedAt: TimeInterval?
    private let queue = DispatchQueue(label: "Verbaline.systemAudioTap", qos: .userInteractive)

    var isRunning: Bool { procID != nil }
    var startedAt: TimeInterval? { lock.withLock { _startedAt } }
    /// The rate of what takeNew() returns (known after start()).
    var sampleRate: Double { format?.sampleRate ?? 48_000 }

    func start() throws {
        guard procID == nil else { return }
        lock.withLock { native.removeAll(keepingCapacity: true); _startedAt = nil }

        let desc = processes.map { CATapDescription(stereoMixdownOfProcesses: Self.processObjects($0)) }
            ?? CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        desc.isPrivate = true
        desc.muteBehavior = .unmuted   // you keep hearing everything normally
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw TapError.create(err) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else { cleanup(); throw TapError.format(err) }
        format = fmt

        let outputUID = (try? AudioHardwareSystem.shared.defaultOutputDevice?.uid) ?? nil ?? ""
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Verbaline system audio", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID, kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard err == noErr else { cleanup(); throw TapError.aggregate(err) }

        var newProc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggID, queue) { [weak self] _, input, _, _, _ in
            self?.append(input)
        }
        guard err == noErr, let newProc else { cleanup(); throw TapError.ioProc(err) }
        procID = newProc
        err = AudioDeviceStart(aggID, newProc)
        guard err == noErr else { cleanup(); throw TapError.start(err) }
    }

    /// Everything captured since start(), as 16 kHz mono. Safe to call when not running (returns []).
    func stop() -> [Float] {
        guard procID != nil else { return [] }
        cleanup()
        let (mono, rate) = lock.withLock { (native, format?.sampleRate ?? 48_000) }
        return Self.resample(mono, from: rate, to: 16_000)
    }

    /// Samples captured since the last call (or start()), mono at `sampleRate`.
    func takeNew() -> [Float] {
        lock.withLock { let out = native; native.removeAll(keepingCapacity: true); return out }
    }

    private func append(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, let p = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        lock.lock(); defer { lock.unlock() }
        if _startedAt == nil { _startedAt = ProcessInfo.processInfo.systemUptime }
        if channels == 1 {
            native.append(contentsOf: UnsafeBufferPointer(start: p, count: frames))
        } else {
            for f in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += p[f * channels + c] }
                native.append(s / Float(channels))
            }
        }
    }

    private func cleanup() {
        if let procID {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        procID = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }

    deinit { cleanup() }

    /// Verbaline's own Core Audio process object, so its chimes aren't in the reference.
    private static func ownProcessObject() -> AudioObjectID? { processObject(getpid()) }

    /// Core Audio's process objects for these pids (processes that never touched audio have none and are skipped).
    static func processObjects(_ pids: [pid_t]) -> [AudioObjectID] { pids.compactMap(processObject) }

    static func processObject(_ pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return err == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard !x.isEmpty, from != to,
              let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(x.count)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(x.count) * to / from) + 1024)
        else { return x }
        inBuf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        var fed = false
        conv.convert(to: outBuf, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }
}
