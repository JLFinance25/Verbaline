import AVFoundation
import CoreAudio

/// Captures a microphone and converts it to mono Float32 at 16 kHz.
///
/// It prefers the Mac's built-in mic: using AirPods' mic flips them into Bluetooth "call" mode,
/// which pauses music and drops it to low quality. With the built-in mic, AirPods stay in music mode
/// and music in your ears never reaches the mic.
///
/// Apple's voice processing (FaceTime's echo cancellation) is used only when sound is playing out loud
/// through the Mac's own speakers — the one case where music can leak into the mic.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    /// 0…1 loudness, delivered on the main thread ~45×/s while recording.
    var onLevel: ((Float) -> Void)?

    /// Applies to the next `start()`.
    var noiseReduction = true {
        didSet { if noiseReduction != oldValue { engineNeedsRebuild = true } }
    }
    private(set) var noiseReductionActive = false

    /// Record from the Mac's built-in mic even when AirPods/headsets are the system default. Applies to the next `start()`.
    var preferBuiltInMic = true {
        didSet { if preferBuiltInMic != oldValue { engineNeedsRebuild = true } }
    }
    private(set) var usingBuiltInMic = false
    /// Diagnostics for the last start(): formats and how many audio buffers actually arrived.
    private(set) var lastInputFormat = ""
    /// Audio buffers delivered since the last start(). Safe to read from any thread.
    var buffersReceived: Int { lock.lock(); defer { lock.unlock() }; return _buffersReceived }
    private var builtForSpeakers: Bool?

    private var engine: AVAudioEngine?
    private var engineNeedsRebuild = true
    private var configObserver: NSObjectProtocol?
    // Shared with the audio thread — only touched while holding `lock`.
    private var converter: AVAudioConverter?
    private var monoInput: AVAudioFormat?
    private var samples: [Float] = []
    private var _buffersReceived = 0
    private var accepting = false
    private let lock = NSLock()

    private var micCapture: MicCapture?     // reused between recordings; rebuilt by invalidateEngine()
    private var activeCapture: MicCapture?  // set while a capture-path recording is running
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: AudioRecorder.sampleRate,
                                             channels: 1, interleaved: false)!

    enum RecorderError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input available" }
    }

    func start() throws {
        // The built-in mic is recorded through AVCaptureSession, which never touches the AirPods (see MicCapture).
        // AVAudioEngine is used only when echo cancellation is needed — sound playing out loud on the Mac's
        // speakers — or when the user turned "Use MacBook Microphone" off.
        let wantEchoCancellation = noiseReduction && Self.defaultOutputIsBuiltIn()
        if preferBuiltInMic, !wantEchoCancellation, let capture = builtInCapture() {
            resetBuffers()
            setAccepting(true)
            capture.start()
            activeCapture = capture
            usingBuiltInMic = true
            noiseReductionActive = false
            lastInputFormat = "capture:16000Hz/1ch"
            return
        }
        activeCapture = nil
        do {
            try startEngine()
        } catch {
            // A stale engine (mic unplugged, AirPods switched) — rebuild once and retry.
            engineNeedsRebuild = true
            try startEngine()
        }
        setAccepting(true)
    }

    /// Stops capture and returns everything recorded since `start()`.
    @discardableResult
    func stop() -> [Float] {
        if let capture = activeCapture {
            capture.stop()
            activeCapture = nil
        } else if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.lock(); defer { lock.unlock() }
        accepting = false            // a late callback must not leak into the next recording
        converter = nil
        let out = samples
        samples.removeAll()
        return out
    }

    // MARK: - Engine

    /// The engine is kept between recordings (voice processing is slow to set up, and a slow start
    /// would clip your first word). It's rebuilt only when the audio hardware changes.
    private func makeEngineIfNeeded() -> AVAudioEngine {
        // Plugging in / connecting headphones changes whether echo cancellation is needed.
        let speakersPlaying = Self.defaultOutputIsBuiltIn()
        if let engine, !engineNeedsRebuild, builtForSpeakers == speakersPlaying { return engine }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine?.stop()

        let engine = AVAudioEngine()
        builtForSpeakers = speakersPlaying
        noiseReductionActive = false
        usingBuiltInMic = false
        if noiseReduction && speakersPlaying {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                // Don't turn down the user's music/video while dictating.
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                noiseReductionActive = true
            } catch {
                NSLog("Verbaline: voice processing unavailable (%@) — recording without it", error.localizedDescription)
            }
        }
        // Pin the input to the built-in mic (voice processing picks its own devices, so only without it).
        if preferBuiltInMic, !noiseReductionActive, let device = Self.builtInInputDevice(),
           let unit = engine.inputNode.audioUnit {
            var id = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            usingBuiltInMic = status == noErr
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.engineNeedsRebuild = true }

        self.engine = engine
        engineNeedsRebuild = false
        return engine
    }

    private func startEngine() throws {
        let engine = makeEngineIfNeeded()
        let input = engine.inputNode
        var inFormat = input.outputFormat(forBus: 0)
        if usingBuiltInMic {
            // After pinning a device, the node still reports the old default mic's rate (e.g. AirPods at 24 kHz),
            // and macOS can't resample on the input side — so a tap in that format receives nothing.
            // Tap at the pinned mic's own hardware rate instead.
            let hw = input.inputFormat(forBus: 0)
            if hw.sampleRate > 0, let native = Self.floatFormat(sampleRate: hw.sampleRate, channels: hw.channelCount) {
                inFormat = native
            }
        }
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RecorderError.noInput }

        // Voice processing on macOS can hand back several channels; channel 0 is the cleaned mic.
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate,
                                 channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: mono, to: targetFormat) else { throw RecorderError.noInput }
        lock.lock()
        self.converter = converter
        self.monoInput = mono
        samples.removeAll(keepingCapacity: true)
        _buffersReceived = 0
        lock.unlock()
        lastInputFormat = "out:\(inFormat.sampleRate)Hz/\(inFormat.channelCount)ch hw:\(input.inputFormat(forBus: 0).sampleRate)Hz/\(input.inputFormat(forBus: 0).channelCount)ch"

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Forces a fresh engine/capture session on the next start() — e.g. after the mic stopped delivering audio.
    func invalidateEngine() {
        engineNeedsRebuild = true
        micCapture = nil
    }

    private func builtInCapture() -> MicCapture? {
        if let micCapture { return micCapture }
        guard let device = MicCapture.builtInDevice(), let capture = MicCapture(device: device) else { return nil }
        capture.onSamples = { [weak self] chunk in
            guard let self else { return }
            self.lock.lock(); self._buffersReceived += 1; self.lock.unlock()
            self.append(chunk)
        }
        micCapture = capture
        return capture
    }

    private func resetBuffers() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        _buffersReceived = 0
        lock.unlock()
    }

    private func setAccepting(_ on: Bool) {
        lock.lock(); accepting = on; lock.unlock()
    }

    /// Deinterleaved Float32 at the device's rate. `standardFormat` returns nil above 2 channels
    /// (some Macs' built-in mic arrays), so those get an explicit discrete channel layout.
    private static func floatFormat(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat? {
        if channels <= 2 { return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
    }

    // MARK: - Core Audio device lookup

    private static func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
        return status == noErr ? result : value
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        property(device, kAudioDevicePropertyTransportType, default: UInt32(0))
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// The Mac's own microphone (e.g. "MacBook Pro Microphone"), if it has one.
    static func builtInInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { transportType($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    /// True when sound is going out of the Mac's built-in speakers (not AirPods/headphones/monitor).
    static func defaultOutputIsBuiltIn() -> Bool {
        let output: AudioDeviceID = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                             default: AudioDeviceID(0))
        guard output != 0, transportType(output) == kAudioDeviceTransportTypeBuiltIn else { return false }
        // The built-in jack shares the transport type; its data source tells headphones ('hdpn') from speakers ('ispk').
        let source: UInt32 = property(output, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, default: UInt32(0))
        return source != 0x6864_706E // 'hdpn'
    }

    // MARK: - Processing (audio thread)

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        _buffersReceived += 1
        let converter = self.converter, monoInput = self.monoInput
        lock.unlock()
        guard let converter, let monoInput, let src = buffer.floatChannelData, buffer.frameLength > 0 else { return }

        // Take channel 0 as a mono buffer.
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoInput, frameCapacity: buffer.frameLength) else { return }
        mono.frameLength = buffer.frameLength
        mono.floatChannelData![0].update(from: src[0], count: Int(buffer.frameLength))

        let ratio = targetFormat.sampleRate / monoInput.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let data = out.floatChannelData, out.frameLength > 0 else { return }

        append(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// Stores 16 kHz mono samples and reports the level. Called on the audio/capture thread.
    private func append(_ chunk: UnsafeBufferPointer<Float>) {
        let n = chunk.count
        guard n > 0 else { return }
        var sumSquares: Float = 0
        for s in chunk { sumSquares += s * s }
        lock.lock()
        guard accepting else { lock.unlock(); return }
        samples.append(contentsOf: chunk)
        lock.unlock()

        let rms = (sumSquares / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let level = min(1, max(0, (db + 55) / 40))
        if let onLevel {
            DispatchQueue.main.async { onLevel(level) }
        }
    }
}
