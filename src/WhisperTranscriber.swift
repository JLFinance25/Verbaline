import Foundation

// WhisperTranscriber
// ------------------
// Turns 16 kHz mono Float32 audio into text with whisper.cpp, entirely on this Mac.
//
//     load()                         -> loads the model once (slow, ~0.4 s); call at launch, off the main thread
//     transcribe(samples:prompt:)    -> text ("" if nothing was said); calls run one at a time
//
// `prompt` is a glossary of names and terms ("Glossary: Okonkwo, HELOC, ..."). Whisper treats it as
// text that came just before the audio, which nudges it toward those spellings. Whisper only reads
// about the last 224 tokens of it, so the glossary is capped (see `glossary(from:)`).

final class WhisperTranscriber: @unchecked Sendable {
    enum Failure: Error { case modelMissing(String), loadFailed, transcribeFailed(Int32) }

    let modelPath: String
    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "Verbaline.whisper", qos: .userInitiated)
    private let language = strdup("en")

    static let backendDir = ProcessInfo.processInfo.environment["VERBALINE_GGML_BACKENDS"] ?? "/opt/homebrew/opt/ggml/libexec"

    init(modelPath: String) { self.modelPath = modelPath }

    deinit {
        if let ctx { whisper_free(ctx) }
        free(language)
    }

    /// Frees the model. Call before the app exits: the GPU code asserts if it is still loaded at exit.
    func unload() {
        queue.sync {
            if let ctx { whisper_free(ctx) }
            ctx = nil
        }
    }

    var isLoaded: Bool { queue.sync { ctx != nil } }

    func load() throws {
        try queue.sync {
            guard ctx == nil else { return }
            guard FileManager.default.fileExists(atPath: modelPath) else { throw Failure.modelMissing(modelPath) }
            // whisper.cpp's GPU (Metal) and CPU code are separate add-on files; the command-line tool
            // loads them itself, an app has to ask. Homebrew keeps them in ggml's libexec folder.
            ggml_backend_load_all_from_path(Self.backendDir)
            var cparams = whisper_context_default_params()
            cparams.use_gpu = true
            guard let c = whisper_init_from_file_with_params(modelPath, cparams) else { throw Failure.loadFailed }
            ctx = c
            // Warm-up: the first decode sets up the GPU and is much slower than later ones.
            _ = try? run(c, samples: [Float](repeating: 0, count: 16_000), prompt: "")
        }
    }

    func transcribe(samples: [Float], prompt: String) throws -> String {
        try queue.sync {
            guard let c = ctx else { throw Failure.loadFailed }
            return try run(c, samples: samples, prompt: prompt)
        }
    }

    // Caller must be on `queue`.
    private func run(_ c: OpaquePointer, samples: [Float], prompt: String) throws -> String {
        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        p.language = UnsafePointer(language)
        p.detect_language = false
        p.no_context = true
        p.no_timestamps = true
        p.single_segment = false
        p.print_special = false
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.suppress_blank = true
        p.suppress_nst = true          // no "(music)" / "[applause]" style tokens

        let promptC = prompt.isEmpty ? nil : strdup(prompt)
        defer { free(promptC) }
        p.initial_prompt = UnsafePointer(promptC)

        let rc = samples.withUnsafeBufferPointer { whisper_full(c, p, $0.baseAddress, Int32($0.count)) }
        guard rc == 0 else { throw Failure.transcribeFailed(rc) }

        var text = ""
        for i in 0..<whisper_full_n_segments(c) {
            if let s = whisper_full_get_segment_text(c, i) { text += String(cString: s) }
        }
        return Self.clean(text)
    }

    /// Drops the bracketed non-speech markers Whisper sometimes still writes ("[BLANK_AUDIO]",
    /// "(silence)") and tidies spaces.
    static func clean(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the glossary prompt from the word list, capped so Whisper doesn't silently cut it.
    /// Earlier entries win; the cap is a rough stand-in for 224 tokens.
    static let fillerStyle = "Um, so, uh, I was like, um, thinking about it."

    static func glossary(from terms: [String], maxCharacters: Int = 540) -> String {
        var out = ""
        for term in terms {
            let piece = out.isEmpty ? term : ", " + term
            if out.count + piece.count > maxCharacters { break }
            out += piece
        }
        // The filler sentence makes Whisper write "um"/"uh" literally instead of guessing a real word
        // ("am", "oh", "MCC"); the cleanup step then removes them.
        return fillerStyle + (out.isEmpty ? "" : " Glossary: " + out + ".")
    }
}
