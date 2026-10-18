import Foundation
import CoreAudio
import AVFoundation

// MeetingAudio
// ------------
// How the notetaker hears a meeting, in any app.
//
//     MeetingDetector   notices a meeting: another app has been using the mic for ~3 s → onStart(app);
//                       no app has used the mic for ~5 s → onEnd(). Verbaline itself never counts.
//     MeetingRecorder   records "You" (your mic) and "Them" (only the meeting app's sound, through a process
//                       tap, so music in other apps is never recorded). takeNew() hands back both as 16 kHz
//                       mono, lined up in time and the same length.
//
// "Which app is it": Core Audio lists every process doing audio (kAudioHardwarePropertyProcessObjectList) and
// whether its input is running (kAudioProcessPropertyIsRunningInput, macOS 14+). Apps do their audio in helper
// processes (Chrome's audio service, Safari's WebKit GPU process), so processes are grouped by the app macOS
// holds responsible for them (the same grouping Activity Monitor uses).
//
// iPhone calls on the Mac: see docs/notetaker-iphone-calls.md for which process carries them and how that was found.

// MARK: - Audio processes

/// One process Core Audio knows about, and which app it belongs to.
struct AudioProcess {
    let object: AudioObjectID
    let pid: pid_t
    let owner: pid_t              // the app responsible for it (itself for a normal app or a daemon)
    let bundleID: String?
    let executable: String        // file name, e.g. "Google Chrome Helper"
    let usingMic: Bool
    let playing: Bool

    /// Every process currently known to Core Audio.
    static func all() -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let pid: pid_t = property(id, kAudioProcessPropertyPID, default: -1)
            guard pid > 0 else { return nil }
            return AudioProcess(object: id, pid: pid, owner: responsiblePID(pid), bundleID: bundleID(id),
                                executable: executablePath(pid).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
                                usingMic: property(id, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0,
                                playing: property(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0)
        }
    }

    private static func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                     default value: T) -> T {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result) == noErr ? result : value
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let id = value?.takeRetainedValue() as String?, !id.isEmpty else { return nil }
        return id
    }

    /// The app macOS holds responsible for a process (Chrome for its helpers, Safari for its WebKit processes).
    /// Uses libsystem's responsibility_get_pid_responsible_for_pid, looked up at run time (it isn't in the SDK headers).
    static func responsiblePID(_ pid: pid_t) -> pid_t {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let lookup = responsibleLookup else { return pid }
        let owner = unsafeBitCast(lookup, to: Fn.self)(pid)
        return owner > 0 ? owner : pid
    }
    private static let responsibleLookup = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// The outermost .app folder an executable lives in ("/Applications/Google Chrome.app" for a Chrome helper).
    static func appBundlePath(forExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}

// MARK: - Detector

final class MeetingDetector {
    var onStart: (MeetingApp) -> Void = { _ in }
    var onEnd: () -> Void = {}

    /// The meeting in progress, if onStart has fired and onEnd hasn't.
    private(set) var current: MeetingApp?

    let startAfter: TimeInterval
    let endAfter: TimeInterval
    let pollEvery: TimeInterval
    private var timer: DispatchSourceTimer?
    private var firstSeen: [pid_t: TimeInterval] = [:]   // app (owner pid) → when it was first seen on the mic
    private var currentKey: pid_t?                       // the meeting app (owner pid)
    private var lastMeetingMicUse: TimeInterval = 0      // when the meeting app was last seen on the mic
    private var heldOver: Set<pid_t> = []                // apps still on the mic when the last meeting ended

    init(startAfter: TimeInterval = 3, endAfter: TimeInterval = 5, pollEvery: TimeInterval = 0.5) {
        self.startAfter = startAfter; self.endAfter = endAfter; self.pollEvery = pollEvery
    }

    /// Starts watching. Callbacks arrive on the main thread. Polling (twice a second) is used rather than
    /// property listeners: it's cheap, and it also sees processes that appear and start the mic in one step.
    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: pollEvery, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            self?.step(apps: MeetingDetector.appsUsingMic(), now: ProcessInfo.processInfo.systemUptime)
        }
        timer = t
        t.resume()
    }

    /// Stops watching. A meeting in progress is forgotten without calling onEnd.
    func stop() {
        timer?.cancel(); timer = nil
        firstSeen.removeAll(); current = nil; currentKey = nil; heldOver.removeAll()
    }

    /// One look at who's using the mic. Separate from the timer so tests can drive it with a fake clock.
    func step(apps: [MeetingApp], now: TimeInterval) {
        let owners = Dictionary(apps.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })
        firstSeen = firstSeen.filter { owners[$0.key] != nil }
        for k in owners.keys where firstSeen[k] == nil { firstSeen[k] = now }
        heldOver.formIntersection(owners.keys)

        if let key = currentKey {
            // The meeting ends when the meeting app itself lets go, even if another app (Voice Memos,
            // a browser tab) keeps the mic.
            if owners[key] != nil { lastMeetingMicUse = now }
            else if now - lastMeetingMicUse >= endAfter {
                current = nil; currentKey = nil
                heldOver = Set(owners.keys)   // they were on the mic during this meeting; not a new one
                onEnd()
            }
        } else {
            // The app that has held the mic longest, once it's held it long enough.
            if let (k, since) = firstSeen.filter({ !heldOver.contains($0.key) }).min(by: { $0.value < $1.value }),
               now - since >= startAfter, let app = owners[k] {
                current = app; currentKey = k; lastMeetingMicUse = now
                onStart(app)
            }
        }
    }

    private static func key(_ app: MeetingApp) -> pid_t { app.pids.first.map(AudioProcess.responsiblePID) ?? 0 }

    // MARK: Which apps are using the mic

    /// Apps (other than Verbaline) using the microphone right now, each with every process whose sound belongs to it.
    static func appsUsingMic() -> [MeetingApp] { apps(from: AudioProcess.all(), usingMicOnly: true) }

    /// Groups processes into apps. With usingMicOnly, only apps that have at least one process using the mic.
    static func apps(from processes: [AudioProcess], usingMicOnly: Bool) -> [MeetingApp] {
        let me = getpid()
        let counted = processes.filter { $0.pid != me && !isIgnored($0) }
        let owners = usingMicOnly ? Set(counted.filter(\.usingMic).map(\.owner)) : Set(counted.map(\.owner))
        return owners.sorted().map { owner in
            let pids = counted.filter { $0.owner == owner }.map(\.pid).sorted()
            let (name, bundleID) = describe(owner: owner, fallbackBundleID: counted.first { $0.pid == owner }?.bundleID)
            return MeetingApp(name: name, bundleID: bundleID, pids: pids)
        }
    }

    /// Verbaline itself (any copy) and Apple's always-listening helpers (Siri, Sound Recognition) never make a meeting.
    static func isIgnored(_ p: AudioProcess) -> Bool {
        if ignoredExecutables.contains(p.executable) { return true }
        guard let id = p.bundleID else { return false }
        return id.hasPrefix("local.verbaline") || ignoredBundleIDs.contains(id)
    }
    /// historicalaudiod turns its input on whenever any other app uses the mic and keeps it on a few seconds after
    /// (measured 2026-10-17; it looks like macOS's mic-usage log). It never carries meeting sound.
    static let ignoredExecutables: Set<String> = ["historicalaudiod"]
    static let ignoredBundleIDs: Set<String> = [
        "com.apple.CoreSpeech", "com.apple.corespeechd_system", "com.apple.assistantd",   // Siri
        "com.apple.accessibility.heard",                                                   // Sound Recognition
        "com.apple.SpeechRecognitionCore.speechrecognitiond",                              // Apple dictation
    ]

    /// Friendly names for system helpers that carry a meeting's sound but have no app of their own.
    static let helperNames: [String: String] = [
        "avconferenced": "FaceTime",
        "callservicesd": "iPhone",
    ]

    private static func describe(owner: pid_t, fallbackBundleID: String?) -> (String, String?) {
        guard let path = AudioProcess.executablePath(owner) else { return ("pid \(owner)", fallbackBundleID) }
        if let appPath = AudioProcess.appBundlePath(forExecutable: path), let bundle = Bundle(path: appPath) {
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            return (name, bundle.bundleIdentifier ?? fallbackBundleID)
        }
        let exe = URL(fileURLWithPath: path).lastPathComponent
        if let name = helperNames[exe] { return (name, nil) }
        return (exe, fallbackBundleID)
    }
}

// MARK: - Recorder

final class MeetingRecorder {
    enum RecorderError: LocalizedError {
        case noMic, alreadyRunning
        var errorDescription: String? {
            switch self {
            case .noMic: return "No microphone available to record you"
            case .alreadyRunning: return "Already recording a meeting"
            }
        }
    }

    static let sampleRate = AudioRecorder.sampleRate

    /// Which mic is recording you (shown in diagnostics).
    private(set) var micName = ""
    /// True while the meeting app's sound is being recorded. Safe to read from any thread.
    var hearingThem: Bool { lock.withLock { _hearingThem } }
    /// Called on the main thread when hearingThem changes: false = Them went silent because the app's sound
    /// couldn't be re-attached (the recorder keeps retrying every 2 s); true = it's back.
    var onHearingThemChanged: ((Bool) -> Void)?
    /// Also record processes the app starts later (Chrome starts its audio service lazily). Set before start().
    var followsNewProcesses = true

    private var mic: MicCapture?
    private var tap: SystemAudioTap?
    private var resampler: StreamResampler?
    private var owners: Set<pid_t> = []
    private var lastPids: [pid_t] = []     // the processes last tapped; used to retry when the tap is lost
    private var _hearingThem = false
    var testFailTapStarts = 0              // tests only: make the next N tap starts fail
    private var drainTimer: DispatchSourceTimer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var ticks = 0
    private let queue = DispatchQueue(label: "Verbaline.meetingRecorder", qos: .userInitiated)
    private let lock = NSLock()
    private var aligner: StreamAligner?

    /// Starts recording you (the Mac's built-in mic, or the default mic if it has none) and the meeting app.
    /// The built-in mic is used even with AirPods: it hears you fine, keeps AirPods out of the way, and with
    /// headphones it doesn't hear Them. Throws if the mic can't be opened; if only the app's sound fails
    /// (no System Audio Recording permission), it throws that error too, so the caller can explain.
    func start(app: MeetingApp) throws {
        guard mic == nil else { throw RecorderError.alreadyRunning }
        guard let device = MicCapture.builtInDevice() ?? AVCaptureDevice.default(for: .audio),
              let mic = MicCapture(device: device) else { throw RecorderError.noMic }
        let t0 = ProcessInfo.processInfo.systemUptime
        lock.withLock { aligner = StreamAligner(start: t0, rate: Self.sampleRate) }
        owners = Set(app.pids.map(AudioProcess.responsiblePID))
        micName = device.localizedName

        mic.onSamples = { [weak self] chunk in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lock.withLock { self.aligner?.push(Array(chunk), to: .you, endingAt: now) }
        }
        mic.start()
        self.mic = mic

        do {
            try startTap(pids: app.pids)
        } catch {
            stop()
            throw error
        }
        watchOutputDevice()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        drainTimer = timer
        timer.resume()
    }

    /// New samples since the last call, both starting at the same moment and the same length.
    func takeNew() -> (you: [Float], them: [Float]) {
        queue.sync { drainTap() }
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock { aligner?.take(now: now) ?? ([], []) }
    }

    func stop() {
        drainTimer?.cancel(); drainTimer = nil
        if let outputListener {
            var addr = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, outputListener)
        }
        outputListener = nil
        mic?.stop(); mic = nil
        queue.sync {
            _ = tap?.stop(); tap = nil; resampler = nil
        }
        lock.withLock { _hearingThem = false }
        lock.withLock { aligner = nil }
    }

    deinit { stop() }

    // MARK: Internals (on `queue` unless noted)

    /// Called from start() before the timer exists, so it's safe off-queue there.
    private func startTap(pids: [pid_t]) throws {
        lastPids = pids
        let tap = SystemAudioTap(processes: pids.filter { $0 != getpid() })
        if testFailTapStarts > 0 { testFailTapStarts -= 1; setHearingThem(false); throw SystemAudioTap.TapError.start(-1) }
        do { try tap.start() } catch { setHearingThem(false); throw error }
        self.tap = tap
        resampler = StreamResampler(from: tap.sampleRate, to: Self.sampleRate)
        setHearingThem(true)
    }

    private func setHearingThem(_ on: Bool) {
        let changed = lock.withLock { () -> Bool in
            defer { _hearingThem = on }
            return _hearingThem != on
        }
        if changed, let cb = onHearingThemChanged { DispatchQueue.main.async { cb(on) } }
    }

    private func tick() {
        drainTap()
        ticks += 1
        // Every 2 s: pick up sound processes the app started since. A tap's process list can't be changed
        // while it runs (Core Audio refuses with '!hog' although it says it's settable), so the tap is rebuilt;
        // the fraction of a second it takes is filled with silence.
        guard ticks % 8 == 0 else { return }
        var pids = lastPids
        if followsNewProcesses {
            pids = Array(Set(pids).union(
                AudioProcess.all().filter { owners.contains($0.owner) && $0.pid != getpid() }.map(\.pid))).sorted()
        }
        if tap == nil {
            // The last (re)start failed: keep trying, so one bad moment doesn't silence Them for the whole meeting.
            try? startTap(pids: pids)
        } else if !Set(pids).isSubset(of: Set(lastPids)) {
            restartTap(pids: pids)
        }
    }

    private func restartTap(pids: [pid_t]) {
        drainTap()
        _ = tap?.stop()
        tap = nil; resampler = nil
        restarts += 1
        do { try startTap(pids: pids) } catch {
            NSLog("Verbaline: meeting audio didn't restart: %@", error.localizedDescription)
        }
    }

    /// Restarts made so far (diagnostics and tests).
    private(set) var restarts = 0

    private func drainTap() {
        guard let tap, let resampler else { return }
        let native = tap.takeNew()
        guard !native.isEmpty else { return }
        let samples = resampler.convert(native)
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { aligner?.push(samples, to: .them, endingAt: now) }
    }

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// The tap runs on the current output device's clock, so when that changes (AirPods connect or
    /// disconnect, headphones plugged in) it's rebuilt. The gap is filled with silence by the aligner.
    private func watchOutputDevice() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.lastPids.isEmpty else { return }
            self.restartTap(pids: self.lastPids)
        }
        var addr = Self.defaultOutputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
            outputListener = block
        }
    }
}

// MARK: - Lining up two streams

/// Keeps "you" and "them" lined up: sample i of each was heard at the same moment (start + i / rate).
/// Each chunk is placed by when it arrived; if a stream fell behind (it started late, or paused while a device
/// changed) the gap is filled with silence. take() returns the part both streams have reached.
struct StreamAligner {
    enum Stream { case you, them }
    let start: TimeInterval
    let rate: Double
    /// A stream this far behind where it should be gets silence to catch up (jitter below this is ignored).
    var slack: TimeInterval = 0.15
    /// take() never waits longer than this for a stream that has stopped delivering.
    var maxWait: TimeInterval = 1.0

    private(set) var you: [Float] = []
    private(set) var them: [Float] = []
    private var taken = 0   // samples already handed out (same for both)

    init(start: TimeInterval, rate: Double) { self.start = start; self.rate = rate }

    /// Total samples this stream has reached, counted from `start`.
    func position(_ s: Stream) -> Int { taken + (s == .you ? you.count : them.count) }

    mutating func push(_ samples: [Float], to s: Stream, endingAt time: TimeInterval) {
        let expectedStart = Int(((time - start) * rate).rounded()) - samples.count
        let behind = expectedStart - position(s)
        if behind > Int(slack * rate) { append(Array(repeating: 0, count: behind), to: s) }
        append(samples, to: s)
    }

    mutating func take(now: TimeInterval) -> (you: [Float], them: [Float]) {
        // A stream that has gone quiet (no chunks at all) is padded so the other isn't held back forever.
        let floor = Int(((now - start - maxWait) * rate).rounded())
        for s in [Stream.you, .them] where position(s) < floor {
            append(Array(repeating: 0, count: floor - position(s)), to: s)
        }
        let n = min(you.count, them.count)
        guard n > 0 else { return ([], []) }
        let out = (Array(you.prefix(n)), Array(them.prefix(n)))
        you.removeFirst(n); them.removeFirst(n)
        taken += n
        return out
    }

    private mutating func append(_ x: [Float], to s: Stream) {
        if s == .you { you.append(contentsOf: x) } else { them.append(contentsOf: x) }
    }
}

// MARK: - Resampling a stream

/// Converts a mono stream chunk by chunk with one converter, so there are no clicks at chunk edges.
final class StreamResampler {
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat

    init(from: Double, to: Double) {
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false)!
        outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false)!
        converter = from == to ? nil : AVAudioConverter(from: inFormat, to: outFormat)
    }

    func convert(_ x: [Float]) -> [Float] {
        guard let converter, !x.isEmpty else { return x }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(x.count)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat,
                                            frameCapacity: AVAudioFrameCount(Double(x.count) * outFormat.sampleRate / inFormat.sampleRate) + 64)
        else { return [] }
        inBuf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        var fed = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        guard error == nil else { return [] }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }
}
