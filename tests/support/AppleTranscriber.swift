import Foundation
import AVFoundation
import Speech

// AppleTranscriber
// ----------------
// On-device speech-to-text for one complete recording, built on the macOS 26
// SpeechAnalyzer API. No network, no third-party models.
//
// Public surface used by the app:
//     init(locale:)                     -> AppleTranscriber
//     prepare() async throws            -> installs / warms Apple's speech model (call once at launch)
//     transcribe(samples:sampleRate:)   -> final, punctuated text ("" if nothing was said)
//     vocabulary: [String]              -> words/phrases to bias recognition toward (personal dictionary)
//
// Design notes:
//  * Engine: SpeechTranscriber (not DictationTranscriber). On our test clips it punctuated and
//    capitalized correctly by default, heard "two pay stubs" correctly where DictationTranscriber
//    heard "tooth paystub's", and was faster on long clips.
//  * A fresh SpeechTranscriber + SpeechAnalyzer is created for every call (an analyzer is
//    one-shot: once its input finishes it cannot be restarted). The expensive part, the model
//    itself, stays resident because the analyzer is created with `.processLifetime`
//    retention and the locale is reserved with AssetInventory in prepare().
//  * transcribe() calls are run ONE AT A TIME. Two SpeechAnalyzers running at once in the same
//    process intermittently hang forever inside finalizeAndFinishThroughEndOfInput() (we saw
//    this in testing), so overlapping calls queue up behind each other instead.
//  * Every call also has a timeout, so if Apple's analyzer ever hangs anyway the caller gets an
//    error instead of a frozen app.
//  * Audio is converted once, up front, to the analyzer's preferred format and fed as a
//    single buffer through an AsyncStream<AnalyzerInput>.
//  * `vocabulary` is passed to each fresh analyzer as AnalysisContext.contextualStrings[.general]
//    (via SpeechAnalyzer.setContext) before audio starts. It is a hint, not a guarantee: if
//    setting it fails, transcription carries on without it. An empty vocabulary skips the
//    call entirely, so behavior is identical to a transcriber that never had this feature.
//    MEASURED (macOS 26.x, tests/dictionary_test.swift): SpeechTranscriber (the default engine)
//    currently IGNORES these hints. Output was identical with and without them, however they were
//    attached (before/after start, via the init, other tag names), and the call costs ~0 ms.
//    DictationTranscriber honors them and fixes names and jargon, but gets much slower as the list
//    grows (17 s clip: 284 ms with none, 506 ms with 42 terms, 1.9 s with 500) and its text has
//    little punctuation. SpeechTranscriber stays flat (about 290 ms at every list size). So for the
//    default engine, the personal dictionary's real effect comes from PersonalDictionary.apply(to:),
//    not from this property. The property stays wired in case a later OS starts using the hints.

@available(macOS 26.0, *)
final class AppleTranscriber: @unchecked Sendable {

    /// Which Apple recognizer to use. `.speech` (SpeechTranscriber) is the default and the one the app uses.
    enum Engine: String {
        /// SpeechTranscriber: the new macOS 26 model. Adds punctuation and capitalization by default.
        case speech
        /// DictationTranscriber: the classic dictation model, with `.punctuation` switched on.
        case dictation
    }

    enum TranscriberError: LocalizedError {
        case unsupportedLocale(String)
        case noAudioFormat
        case conversionFailed(String)
        case timedOut(seconds: Double)

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let id): return "Speech recognition does not support locale \(id) on this Mac."
            case .noAudioFormat: return "The speech analyzer did not report a compatible audio format."
            case .conversionFailed(let why): return "Audio conversion failed: \(why)"
            case .timedOut(let s): return String(format: "Speech recognition did not finish within %.0f s.", s)
            }
        }
    }

    private let requestedLocale: Locale
    private let engine: Engine
    private struct State {
        var resolvedLocale: Locale?
        var cachedFormat: AVAudioFormat?
        var prepared = false
        var vocabulary: [String] = []
    }
    private let lock = NSLock()
    private var state = State()
    private let gate = SerialGate()
    // Read per use, so tests can change them while the process runs.
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var debug: Bool { env["VERBALINE_STT_DEBUG"] != nil }

    /// Seconds of silence appended after the speech. Harmless, and cheap insurance for recordings
    /// that stop abruptly on key release. (No measurable effect on our synthetic test clips.)
    private let tailSilenceSeconds = 0.5

    convenience init(locale: Locale = Locale(identifier: "en-US")) {
        self.init(locale: locale, engine: .speech)
    }

    /// Same as `init(locale:)` but lets tests pick the recognizer.
    init(locale: Locale, engine: Engine) {
        self.requestedLocale = locale
        self.engine = engine
    }

    // MARK: - vocabulary

    /// Words/phrases to bias recognition toward (names, jargon, acronyms). Safe to set from any
    /// thread at any time; applies to the next transcribe() call (a call already running keeps
    /// the list it started with). Entries are trimmed, empty ones dropped, duplicates removed
    /// (ignoring case), and the list is capped at `maxVocabularyTerms`.
    var vocabulary: [String] {
        get { lock.withLock { state.vocabulary } }
        set {
            let cleaned = Self.sanitizeVocabulary(newValue)
            lock.withLock { state.vocabulary = cleaned }
        }
    }

    /// Upper bound on how many hint strings are handed to the recognizer.
    static let maxVocabularyTerms = 500
    /// Longest single hint, in characters. Longer entries are not names or jargon; skip them.
    static let maxVocabularyTermLength = 80

    static func sanitizeVocabulary(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in terms {
            let t = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !t.isEmpty, t.count <= maxVocabularyTermLength else { continue }
            guard seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
            if out.count >= maxVocabularyTerms { break }
        }
        return out
    }

    // MARK: - prepare

    /// Make sure the on-device speech model is installed and loaded. Safe to call repeatedly.
    func prepare() async throws {
        let t0 = Date()
        let locale = try await resolveLocale()

        let module = makeModule(locale: locale)
        try await installAssetsIfNeeded(for: module)

        // Keep the model resident. Reserving can fail (e.g. reservation limit); that is not fatal.
        _ = try? await AssetInventory.reserve(locale: locale)

        let format = try await bestFormat(for: module)
        lock.withLock { state.cachedFormat = format }

        // Warm the model: load it by running a throwaway analyzer through prepareToAnalyze.
        // Done through the same gate as transcribe() so it never overlaps a real analysis.
        await gate.acquire()
        do {
            // Timed, like every analysis: a hang here would otherwise hold the gate forever and freeze every dictation.
            let options = Self.analyzerOptions
            try await withTimeout(seconds: 60) {
                let analyzer = SpeechAnalyzer(modules: [module], options: options)
                try await analyzer.prepareToAnalyze(in: format)
            }
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()

        lock.withLock { state.prepared = true }
        log("prepare() finished in \(ms(since: t0)) ms (engine=\(engine.rawValue), locale=\(locale.identifier), format=\(format))")
    }

    // MARK: - transcribe

    /// Transcribe one complete recording. `samples` = mono Float32 PCM in [-1, 1] at `sampleRate` Hz.
    /// Returns the final text, trimmed, with punctuation and capitalization. "" if nothing was said.
    /// Overlapping calls are queued and run one after another.
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        // Under ~50 ms there cannot be a word in it.
        guard sampleRate > 0, Double(samples.count) / sampleRate >= 0.05 else { return "" }

        await gate.acquire()
        do {
            let text = try await transcribeExclusively(samples: samples, sampleRate: sampleRate)
            await gate.release()
            return text
        } catch {
            await gate.release()
            throw error
        }
    }

    /// The actual work. Only ever called while holding `gate`.
    private func transcribeExclusively(samples: [Float], sampleRate: Double) async throws -> String {
        let t0 = Date()
        if !lock.withLock({ state.prepared }) {
            // Caller forgot prepare(): do it now. (Re-enters the gate-free parts only.)
            try await prepareWhileHoldingGate()
        }
        let locale = try await resolveLocale()
        let vocabulary = lock.withLock { state.vocabulary }

        let module = makeModule(locale: locale)
        let format: AVAudioFormat
        if let cached = lock.withLock({ state.cachedFormat }) {
            format = cached
        } else {
            format = try await bestFormat(for: module)
        }

        let buffer = try Self.makeBuffer(samples: samples, sampleRate: sampleRate,
                                         target: format, tailSilenceSeconds: tailSilenceSeconds)
        log("setup+convert: \(ms(since: t0)) ms")

        // Normal processing takes ~1-2% of the audio length. Allow far more than that.
        let audioSeconds = Double(samples.count) / sampleRate
        let limit = Double(env["VERBALINE_STT_TIMEOUT"] ?? "") ?? (8 + audioSeconds * 0.5)

        let text: String
        switch engine {
        case .speech:
            guard let m = module as? SpeechTranscriber else { return "" }
            text = try await withTimeout(seconds: limit) { [self] in
                try await run(module: m, buffer: buffer, vocabulary: vocabulary) { String($0.text.characters) }
            }
        case .dictation:
            guard let m = module as? DictationTranscriber else { return "" }
            text = try await withTimeout(seconds: limit) { [self] in
                try await run(module: m, buffer: buffer, vocabulary: vocabulary) { String($0.text.characters) }
            }
        }
        log("transcribe() total: \(ms(since: t0)) ms")
        return text
    }

    /// prepare() for the rare case where transcribe() is called first. We already hold the gate,
    /// so this must not take it again.
    private func prepareWhileHoldingGate() async throws {
        let locale = try await resolveLocale()
        let module = makeModule(locale: locale)
        try await installAssetsIfNeeded(for: module)
        _ = try? await AssetInventory.reserve(locale: locale)
        let format = try await bestFormat(for: module)
        lock.withLock { state.cachedFormat = format; state.prepared = true }
    }

    // MARK: - analyzer plumbing

    private static var analyzerOptions: SpeechAnalyzer.Options {
        SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
    }

    /// Drive one analyzer over one buffer and return the joined final text.
    private func run<M: SpeechModule>(module: M,
                                      buffer: AVAudioPCMBuffer,
                                      vocabulary: [String],
                                      text: @escaping @Sendable (M.Result) -> String) async throws -> String {
        let t0 = Date()
        let analyzer = SpeechAnalyzer(modules: [module], options: Self.analyzerOptions)

        // If this task is cancelled (timeout), tell the analyzer to stop so it does not linger.
        return try await withTaskCancellationHandler {
            // Start collecting results before any audio goes in, so nothing is missed.
            let collector = Task { () -> [String] in
                var pieces: [String] = []
                for try await result in module.results {
                    // Without .volatileResults every result is final, but be explicit.
                    guard result.isFinal else { continue }
                    pieces.append(text(result))
                }
                return pieces
            }

            do {
                // Bias recognition toward the user's own words. Must happen before audio starts.
                // A failure here only costs the hint, never the dictation. Cancellation is not
                // swallowed, so a timeout still unwinds promptly.
                if !vocabulary.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = vocabulary
                    do {
                        try await analyzer.setContext(context)
                        log("  context set (\(vocabulary.count) terms) in \(ms(since: t0)) ms")
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        log("  setContext failed, continuing without vocabulary: \(error)")
                    }
                }
                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                try await analyzer.start(inputSequence: stream)
                log("  analyzer started")
                continuation.yield(AnalyzerInput(buffer: buffer))
                continuation.finish()
                log("  input fed and finished")
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                log("  finalizeAndFinishThroughEndOfInput returned")
                let pieces = try await collector.value
                log("analyze: \(ms(since: t0)) ms, \(pieces.count) result segment(s)")
                return Self.join(pieces)
            } catch {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Join result segments, making sure words from adjacent segments do not run together,
    /// then tidy whitespace.
    private static func join(_ pieces: [String]) -> String {
        var out = ""
        for piece in pieces {
            let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            if !out.isEmpty { out += " " }
            out += p
        }
        // Collapse any run of spaces/newlines to a single space.
        let collapsed = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - model / assets

    private func makeModule(locale: Locale) -> any SpeechModule {
        switch engine {
        case .speech:
            // No transcription options: SpeechTranscriber punctuates and capitalizes by default.
            // No reporting options: we only want final results, not volatile (partial) ones.
            return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        case .dictation:
            return DictationTranscriber(locale: locale,
                                        contentHints: [],
                                        transcriptionOptions: [.punctuation],
                                        reportingOptions: [],
                                        attributeOptions: [])
        }
    }

    private func resolveLocale() async throws -> Locale {
        if let existing = lock.withLock({ state.resolvedLocale }) { return existing }

        let supported: Locale?
        switch engine {
        case .speech: supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        case .dictation: supported = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale)
        }
        guard let supported else { throw TranscriberError.unsupportedLocale(requestedLocale.identifier) }
        lock.withLock { state.resolvedLocale = supported }
        return supported
    }

    private func installAssetsIfNeeded(for module: any SpeechModule) async throws {
        let status = await AssetInventory.status(forModules: [module])
        log("asset status: \(status)")
        if status == .installed { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            log("downloading Apple speech model ...")
            try await request.downloadAndInstall()
        }
    }

    private func bestFormat(for module: any SpeechModule) async throws -> AVAudioFormat {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError.noAudioFormat
        }
        return format
    }

    // MARK: - audio conversion

    /// Build one AVAudioPCMBuffer in `target` format from mono Float32 samples, plus trailing silence.
    static func makeBuffer(samples: [Float], sampleRate: Double,
                           target: AVAudioFormat, tailSilenceSeconds: Double) throws -> AVAudioPCMBuffer {
        guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: 1, interleaved: false) else {
            throw TranscriberError.conversionFailed("could not create source format")
        }
        let tailFrames = Int(tailSilenceSeconds * sampleRate)
        let totalFrames = samples.count + tailFrames
        guard let src = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(totalFrames)),
              let dst = src.floatChannelData?[0] else {
            throw TranscriberError.conversionFailed("could not allocate source buffer")
        }
        samples.withUnsafeBufferPointer { p in
            if let base = p.baseAddress { dst.update(from: base, count: samples.count) }
        }
        if tailFrames > 0 { (dst + samples.count).update(repeating: 0, count: tailFrames) }
        src.frameLength = AVAudioFrameCount(totalFrames)

        // Already in the analyzer's format: nothing to convert.
        if srcFormat == target { return src }

        guard let converter = AVAudioConverter(from: srcFormat, to: target) else {
            throw TranscriberError.conversionFailed("no converter from \(srcFormat) to \(target)")
        }
        let ratio = target.sampleRate / sampleRate
        let capacity = AVAudioFrameCount((Double(totalFrames) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw TranscriberError.conversionFailed("could not allocate output buffer")
        }

        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return src
        }
        if status == .error || convError != nil {
            throw TranscriberError.conversionFailed(convError?.localizedDescription ?? "unknown converter error")
        }
        return out
    }

    // MARK: - logging

    private func ms(since t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }

    private func log(_ message: @autoclosure () -> String) {
        guard debug else { return }
        FileHandle.standardError.write(Data(("[AppleTranscriber] " + message() + "\n").utf8))
    }
}

// MARK: - helpers (file-private)

/// Lets only one holder in at a time; later callers wait in order. Cancellation-agnostic on purpose:
/// a waiter always gets its turn, so the gate can never be left locked.
@available(macOS 26.0, *)
private actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Hand the gate straight to the next waiter; `busy` stays true.
            waiters.removeFirst().resume()
        }
    }
}

/// Resumes a continuation at most once, whichever caller gets there first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { continuation = c }

    /// Returns true if this call is the one that resumed the continuation.
    @discardableResult
    func resume(with result: Result<T, Error>) -> Bool {
        let c: CheckedContinuation<T, Error>? = lock.withLock {
            let taken = continuation
            continuation = nil
            return taken
        }
        guard let c else { return false }
        c.resume(with: result)
        return true
    }
}

/// A set-once boolean that is safe to touch from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Run `operation`, but give up after `seconds`.
///
/// On timeout the operation is cancelled and given up to 1.5 s to unwind before we report the
/// timeout, so a cancelled analyzer is not still running when the caller's next call starts
/// (overlapping analyzers is exactly what makes Apple's API hang). If the operation ignores
/// cancellation we still report the timeout after the grace period instead of waiting forever,
/// which is why this uses a continuation rather than a task group.
@available(macOS 26.0, *)
private func withTimeout<T: Sendable>(seconds: Double,
                                      operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let once = ResumeOnce(continuation)
        let timedOut = Flag()
        let workDone = Flag()

        let work = Task {
            do {
                // A result that arrives, even during the grace period, is still delivered.
                once.resume(with: .success(try await operation()))
            } catch {
                // After a timeout this error is just our own cancellation; the timer reports it.
                if !timedOut.isSet { once.resume(with: .failure(error)) }
            }
            workDone.set()
        }

        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }   // the work finished first
            timedOut.set()
            work.cancel()
            for _ in 0..<15 where !workDone.isSet {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            once.resume(with: .failure(AppleTranscriber.TranscriberError.timedOut(seconds: seconds)))
        }

        // If the work finishes before the timeout, stop the timer.
        Task {
            _ = await work.result
            timer.cancel()
        }
    }
}
