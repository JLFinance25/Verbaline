import Foundation

// WhisperEngine
// -------------
// Plugs Whisper into the app with the same surface the old Apple engine had, so the rest of the app
// (inherited from Verbaline) didn't have to change:
//
//     vocabulary: [String]                  -> names/terms; sent to Whisper as a glossary prompt
//     prepare() async throws                -> loads the model (once; later calls return at once)
//     transcribe(samples:sampleRate:)       -> text; waits for prepare() if the model is still loading
//     unload()                              -> call before the process exits
//
// Audio must be 16 kHz mono Float32 (AudioRecorder.sampleRate), which is what the recorder delivers.

enum VerbalinePaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Verbaline", isDirectory: true)
    /// The speech model lives in Verbaline's own folder (no folder-access prompts). VERBALINE_MODEL overrides
    /// it (tests, or a smaller model). ModelDownloader fetches it there on first launch.
    static let modelFileName = "ggml-large-v3-turbo.bin"
    static let modelsDir = support.appendingPathComponent("models", isDirectory: true)
    static let model = ProcessInfo.processInfo.environment["VERBALINE_MODEL"]
        ?? modelsDir.appendingPathComponent(modelFileName).path

    /// One-time move from the app's working name ("Murmur") to Verbaline: everything in the old settings folder
    /// (word list, snippets, history, stats, meeting notes) moves over, never overwriting a file that's already
    /// here. Must run before anything opens these files — main.swift calls it first.
    static func migrateFromOldName() {
        let fm = FileManager.default
        let old = support.deletingLastPathComponent().appendingPathComponent("Mur" + "mur")   // split: survives renames
        guard let items = try? fm.contentsOfDirectory(atPath: old.path) else { return }
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        for item in items {
            let dest = support.appendingPathComponent(item)
            if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: old.appendingPathComponent(item), to: dest) }
        }
        if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true { try? fm.removeItem(at: old) }
    }

    /// First launch: start from the word list and snippets you built up in the old app, if they exist.
    /// Never overwrites a file Verbaline already has.
    static func importOldSettings() {
        let fm = FileManager.default
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        let parent = support.deletingLastPathComponent()
        for file in ["dictionary.txt", "snippets.txt"] {
            let dest = support.appendingPathComponent(file)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            for old in ["My" + "Flow"] {   // split so a find-and-replace on the name can't change it
                let src = parent.appendingPathComponent(old).appendingPathComponent(file)
                if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: dest); break }
            }
        }
    }
}

final class WhisperEngine: @unchecked Sendable {
    enum Failure: LocalizedError {
        case wrongSampleRate(Double)
        var errorDescription: String? {
            switch self { case .wrongSampleRate(let r): return "Audio must be 16 kHz (got \(Int(r)) Hz)" }
        }
    }

    private let whisper: WhisperTranscriber
    private let lock = NSLock()
    private var _vocabulary: [String] = []
    private var lastPrewarm: TimeInterval = -1_000
    private var _lastPrewarmSeconds: Double?

    init(modelPath: String = VerbalinePaths.model) { whisper = WhisperTranscriber(modelPath: modelPath) }

    var vocabulary: [String] {
        get { lock.withLock { _vocabulary } }
        set { lock.withLock { _vocabulary = newValue } }
    }

    func prepare() async throws {
        try await Self.offMain { try self.whisper.load() }
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard sampleRate == 16_000 else { throw Failure.wrongSampleRate(sampleRate) }
        try await prepare()
        let prompt = WhisperTranscriber.glossary(from: vocabulary)
        return try await Self.offMain {
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Transcribing")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            return try self.whisper.transcribe(samples: samples, prompt: prompt)
        }
    }

    /// Call when the user starts talking. When the Mac is short on memory it moves the idle model out to
    /// disk, and the first dictation after a break then waited ~6 s for it to come back (measured). A tiny
    /// decode while the user speaks pulls it back in, so the real one finds it ready. Skipped if one ran recently.
    func prewarm() {
        let now = ProcessInfo.processInfo.systemUptime
        let due = lock.withLock { () -> Bool in
            guard now - lastPrewarm > 20 else { return false }
            lastPrewarm = now
            return true
        }
        guard due else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Whisper warm-up")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let t0 = Date()
            _ = try? self.whisper.load()
            _ = try? self.whisper.transcribe(samples: [Float](repeating: 0, count: 8_000), prompt: "")
            self.lock.withLock { self._lastPrewarmSeconds = Date().timeIntervalSince(t0) }
        }
    }

    /// How long the last warm-up took (seconds): ~0.1 when the model was in memory, several when it wasn't.
    var lastPrewarmSeconds: Double? { lock.withLock { _lastPrewarmSeconds } }

    func unload() { whisper.unload() }

    /// Whisper calls block a thread for a few hundred ms; keep them off Swift's shared task threads.
    private static func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(with: Result { try work() }) }
        }
    }
}
