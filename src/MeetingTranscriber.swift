import Foundation

// MeetingTranscriber
// ------------------
// Turns a meeting's sound into transcript lines while the meeting is still going.
//
//     let t = MeetingTranscriber(transcribe: { samples in try await engine.transcribe(samples: samples, sampleRate: 16_000) })
//     let lines = await t.add(you: micSamples, them: appSamples)   // call every second or so; returns new lines
//     let rest  = await t.finish()                                 // at the end: whatever is still buffered
//
// How it works: "You" (your mic) and "Them" (the meeting app's sound) are kept as two separate streams. As soon as
// a stream's speaker pauses (0.7 s of quiet after some talking), the piece up to the pause goes to Whisper, so a
// line appears a second or two after someone stops talking. Someone talking without a pause is cut at the quietest
// moment before 12 s (so a word isn't sliced in half). Text comes back as lines with start times in seconds from
// the start of the meeting. A piece with no speech in it (SpeechGate says so) makes no line.
// (It used to wait for 30 s pieces; in a real meeting that felt far too slow to be "live".)
//
// Memory: only the audio not yet transcribed is held (about 12 s per side at most), never the whole meeting,
// so a 2-hour meeting costs the same as a 2-minute one. The lines themselves are small text and belong to the caller.
//
// removeEchoes is for when the meeting plays on the Mac's speakers: your mic hears the other person too, so
// "You" gets a second, fainter copy of what "Them" said. It drops those copies and keeps real replies.

actor MeetingTranscriber {
    typealias Transcribe = ([Float]) async throws -> String

    static let sampleRate = 16_000
    /// A side is cut at the first pause this long after some talking...
    static let pauseSeconds = 0.7
    /// ...or, if nobody pauses, once it holds this much audio.
    static let chunkSeconds = 12.0
    /// That forced cut is placed at the quietest moment in the last few seconds of the chunk.
    static let cutSearchSeconds = 4.0
    /// Leftover audio shorter than this at the end of the meeting isn't worth sending to Whisper.
    static let minFinalSeconds = 0.4

    private let transcribe: Transcribe
    private let hasSpeech: ([Float]) -> Bool

    private struct Side {
        var buffer: [Float] = []
        var consumed = 0            // samples already cut off the front (gives the chunk's start time)
    }
    private var you = Side()
    private var them = Side()

    /// Turn-taking: an actor lets another call in whenever it awaits, and two transcriptions at once would
    /// break Whisper and scramble the order. Only one add()/finish() works at a time; the rest queue up in order.
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    private func takeTurn() async {
        if busy { await withCheckedContinuation { queue.append($0) } } else { busy = true }
    }
    private func endTurn() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }   // hands the turn straight on
    }

    /// Chunks whose transcription failed (their audio is lost; a placeholder line marks the spot).
    private(set) var failedChunks = 0
    static let notTranscribed = "(audio not transcribed)"

    /// - Parameters:
    ///   - transcribe: 16 kHz mono samples in, text out (WhisperEngine in the app, a fake in tests).
    ///   - hasSpeech: decides whether a chunk has any speech. Defaults to Verbaline's SpeechGate; tests can replace it.
    init(transcribe: @escaping Transcribe,
         hasSpeech: @escaping ([Float]) -> Bool = { SpeechGate.process($0).hasSpeech }) {
        self.transcribe = transcribe
        self.hasSpeech = hasSpeech
    }

    /// Seconds of audio waiting on each side (for tests: proves memory stays bounded).
    var bufferedSeconds: (you: Double, them: Double) {
        (Double(you.buffer.count) / Double(Self.sampleRate), Double(them.buffer.count) / Double(Self.sampleRate))
    }

    /// Adds the newest sound from both sides (same moment, 16 kHz mono) and returns any lines that are now ready.
    func add(you newYou: [Float], them newThem: [Float]) async -> [TranscriptLine] {
        you.buffer += newYou      // stored at once, even if another call is busy; the turn-holder will pick it up
        them.buffer += newThem
        await takeTurn()
        defer { endTurn() }
        var out: [TranscriptLine] = []
        out += await drain(.you, final: false)
        out += await drain(.them, final: false)
        return out.sorted { $0.start < $1.start }
    }

    /// Meeting over: transcribes whatever is left on each side.
    func finish() async -> [TranscriptLine] {
        await takeTurn()
        defer { endTurn() }
        var out: [TranscriptLine] = []
        out += await drain(.you, final: true)
        out += await drain(.them, final: true)
        return out.sorted { $0.start < $1.start }
    }

    // MARK: - Chunking

    private func drain(_ who: Speaker, final: Bool) async -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        let chunkSamples = Int(Self.chunkSeconds * Double(Self.sampleRate))
        while true {
            let side = who == .you ? you : them
            let cut: Int
            if side.buffer.count >= chunkSamples {
                cut = Self.quietestCut(in: side.buffer, near: chunkSamples)
            } else if !final, let pause = Self.pauseCut(in: side.buffer) {
                cut = pause
            } else if final, Double(side.buffer.count) >= Self.minFinalSeconds * Double(Self.sampleRate) {
                cut = side.buffer.count
            } else {
                if final { setSide(who) { $0.buffer.removeAll(); $0.consumed += side.buffer.count } }
                break
            }
            let chunk = Array(side.buffer[..<cut])
            let start = Double(side.consumed) / Double(Self.sampleRate)
            // Take the audio off the buffer before awaiting, so a second add() during transcription can't reuse it.
            setSide(who) { $0.buffer.removeFirst(cut); $0.consumed += cut }
            lines += await linesFor(chunk: chunk, speaker: who, start: start)
        }
        return lines
    }

    private func setSide(_ who: Speaker, _ change: (inout Side) -> Void) {
        if who == .you { change(&you) } else { change(&them) }
    }

    /// Transcribes each stretch of talking in the chunk on its own, so every line starts when it was actually said
    /// (a chunk is often mostly silence while the other person talks) and separate turns stay separate lines.
    private func linesFor(chunk: [Float], speaker: Speaker, start: TimeInterval) async -> [TranscriptLine] {
        guard hasSpeech(chunk) else { return [] }
        var lines: [TranscriptLine] = []
        let sr = Double(Self.sampleRate)
        for r in Self.speechRegions(in: chunk) {
            let piece = Array(chunk[r])
            guard hasSpeech(piece) else { continue }
            let at = start + Double(r.lowerBound) / sr
            // A failed transcription loses these words but must not stop the meeting: carry on, and leave a
            // visible marker so the gap in the record is not mistaken for silence.
            guard let text = try? await transcribe(piece) else {
                failedChunks += 1
                lines.append(TranscriptLine(speaker: speaker, start: at, text: Self.notTranscribed))
                continue
            }
            lines += Self.makeLines(text: text, speaker: speaker, start: at, duration: Double(piece.count) / sr)
        }
        return lines
    }

    /// Where to cut a buffer whose speaker has paused: the end of the talking, once `pauseSeconds` of quiet follow it.
    /// A buffer that is all quiet (2 s or more) is cut whole, so silence doesn't pile up. nil = keep listening.
    static func pauseCut(in x: [Float]) -> Int? {
        let sr = sampleRate
        let regions = speechRegions(in: x, joinGap: pauseSeconds, wholeIfUnsure: false)
        guard let last = regions.last else { return x.count >= 2 * sr ? x.count : nil }
        let quietAfter = x.count - last.upperBound
        return quietAfter + 4 * (sr / 20) >= Int(pauseSeconds * Double(sr)) ? last.upperBound : nil   // + the 0.2 s pad
    }

    /// The stretches of `x` where someone is talking: 50 ms frames louder than the background, joined across pauses
    /// shorter than `joinGap`, padded by 0.2 s each side. Returns the whole chunk when it can't tell (all equally loud).
    static func speechRegions(in x: [Float], joinGap: Double = 1.0, wholeIfUnsure: Bool = true) -> [Range<Int>] {
        let sr = sampleRate, frame = sr / 20
        guard x.count >= frame * 2 else { return x.isEmpty ? [] : [0..<x.count] }
        var rms: [Float] = []
        var i = 0
        while i < x.count {
            let j = min(i + frame, x.count)
            var e: Float = 0
            for k in i..<j { e += x[k] * x[k] }
            rms.append((e / Float(j - i)).squareRoot())
            i = j
        }
        let floor = rms.sorted()[rms.count / 10]         // the quietest tenth = background noise
        let threshold = max(floor * 3, 0.004)
        let loud = rms.map { $0 > threshold }
        // Can't tell talking from background (steady sound throughout): keep the whole chunk, or (pauseCut) say so.
        if !loud.contains(false) { return [0..<x.count] }
        if !loud.contains(true) {
            // Everything equally loud: steady sound (keep it) or real quiet (pauseCut treats it as silence).
            return wholeIfUnsure || floor > 0.004 ? [0..<x.count] : []
        }
        let maxGap = Int(joinGap * 20), pad = 4          // frames (50 ms each)
        var regions: [Range<Int>] = []
        var runStart: Int?, lastLoud = -1
        for (f, on) in loud.enumerated() where on {
            if let s = runStart, f - lastLoud > maxGap {
                regions.append(s..<lastLoud + 1); runStart = f
            } else if runStart == nil { runStart = f }
            lastLoud = f
        }
        if let s = runStart { regions.append(s..<lastLoud + 1) }
        return regions.map { r in max(0, (r.lowerBound - pad) * frame)..<min(x.count, (r.upperBound + pad) * frame) }
    }

    /// Where to cut a buffer that has reached `target` samples: the middle of the quietest 100 ms stretch in
    /// the last `cutSearchSeconds` before `target`. Never earlier than the search window, never past `target`.
    static func quietestCut(in x: [Float], near target: Int) -> Int {
        let sr = sampleRate
        let win = sr / 10, hop = sr / 20
        let lo = max(0, target - Int(cutSearchSeconds * Double(sr)))
        guard target <= x.count, target - lo > win else { return min(target, x.count) }
        var bestStart = lo, bestEnergy = Float.greatestFiniteMagnitude
        var i = lo
        while i + win <= target {
            var e: Float = 0
            for j in i..<i + win { e += x[j] * x[j] }
            // "<=" so that among equally quiet stretches (digital silence) the later one wins: bigger chunks.
            if e <= bestEnergy { bestEnergy = e; bestStart = i }
            i += hop
        }
        return bestStart + win / 2
    }

    // MARK: - Text to lines

    /// Splits `text` into sentence-sized lines and spreads `duration` over them in proportion to their length.
    static func makeLines(text: String, speaker: Speaker, start: TimeInterval, duration: TimeInterval) -> [TranscriptLine] {
        let sentences = splitSentences(text)
        let total = sentences.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        var lines: [TranscriptLine] = []
        var before = 0
        for s in sentences {
            lines.append(TranscriptLine(speaker: speaker, start: start + duration * Double(before) / Double(total), text: s))
            before += s.count
        }
        return lines
    }

    /// Cuts after ". ", "! " or "? " (and at the end). Pieces under 3 words are joined to the previous one,
    /// so "Mr. Smith" or a lone "Yeah." doesn't become its own line.
    static func splitSentences(_ text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        var pieces: [String] = []
        var current = ""
        let chars = Array(t)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let endsSentence = ".!?".contains(c) && (i + 1 == chars.count || chars[i + 1] == " " || chars[i + 1] == "\n")
            // "6.5" has no space after the dot, so it never splits; a closing quote after the mark stays with it.
            if endsSentence {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { pieces.append(s) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { pieces.append(rest) }

        var merged: [String] = []
        for p in pieces {
            if let last = merged.last, wordCount(last) < 3 || wordCount(p) < 3 {
                merged[merged.count - 1] = last + " " + p
            } else {
                merged.append(p)
            }
        }
        return merged
    }

    private static func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }

    // MARK: - Echo removal

    /// Drops a "You" line that is a near-copy of one "Them" line (or two neighbouring ones) from about the same
    /// time: at least 85% of its words appear in the same order, and at least 2 of them are content words
    /// (not "the", "is", "that"...). A reply that merely shares common words, or answers with new words, stays;
    /// so does a read-back that rephrases a number ("so two thousand four fifty a month, right?").
    /// A word-for-word read-back at the same moment looks exactly like an echo and is dropped: unavoidable.
    /// Order is preserved. Lines under 4 words are never dropped.
    static func removeEchoes(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        let theirs = lines.filter { $0.speaker == .them }.sorted { $0.start < $1.start }
            .map { (start: $0.start, words: normalizedWords($0.text)) }
        return lines.filter { line in
            guard line.speaker == .you else { return true }
            let mine = normalizedWords(line.text)
            guard mine.count >= 4 else { return true }
            let near = theirs.indices.filter { abs(theirs[$0].start - line.start) <= echoWindow }
            for i in near {
                if isCopy(mine, of: theirs[i].words) { return false }
                if i + 1 < theirs.count, isCopy(mine, of: theirs[i].words + theirs[i + 1].words) { return false }
            }
            return true
        }
    }

    static let echoWindow = 12.0       // seconds either side
    static let echoThreshold = 0.85    // share of the "You" words found, in order, in what "Them" said

    private static func isCopy(_ mine: [String], of theirs: [String]) -> Bool {
        guard !theirs.isEmpty else { return false }
        let matched = orderedMatches(mine, theirs)
        let hit = matched.filter { $0 }.count
        guard Double(hit) / Double(mine.count) >= echoThreshold else { return false }
        let content = zip(mine, matched).filter { $0.1 && !stopWords.contains($0.0) }.count
        return content >= 2
    }

    /// For each of `mine`, whether it is part of the longest in-order run shared with `theirs` (near-spellings count,
    /// because the speaker-to-mic copy is transcribed a little differently).
    private static func orderedMatches(_ mine: [String], _ theirs: [String]) -> [Bool] {
        let n = mine.count, m = theirs.count
        var L = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n { for j in 1...m {
            L[i][j] = sameWord(mine[i - 1], theirs[j - 1]) ? L[i - 1][j - 1] + 1 : max(L[i - 1][j], L[i][j - 1])
        } }
        var out = Array(repeating: false, count: n)
        var i = n, j = m
        while i > 0 && j > 0 {
            if sameWord(mine[i - 1], theirs[j - 1]) && L[i][j] == L[i - 1][j - 1] + 1 { out[i - 1] = true; i -= 1; j -= 1 }
            else if L[i - 1][j] >= L[i][j - 1] { i -= 1 } else { j -= 1 }
        }
        return out
    }

    static let stopWords: Set<String> = ["a", "an", "the", "i", "you", "he", "she", "it", "we", "they", "me", "my", "your", "our",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "have", "has", "had", "to", "of", "in", "on", "at",
        "for", "with", "and", "or", "but", "so", "that", "this", "what", "will", "would", "can", "could", "just", "if", "then",
        "there", "here", "not", "no", "yes", "okay", "ok", "yeah", "right", "about", "as", "by", "from", "up", "out"]

    private static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 5, b.count >= 5, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(Array(a), Array(b)) <= 1
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    static func normalizedWords(_ s: String) -> [String] {
        s.lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "'" || $0 == " " ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
    }
}
