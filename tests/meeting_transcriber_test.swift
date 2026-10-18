import Foundation
import AVFoundation

// meeting_transcriber_test: MeetingTranscriber's chunking, timing, silence, echo removal and memory use, with a
// fake transcriber; then one real Whisper run on a ~3 minute recording (the test clips joined) compared with
// transcribing the whole thing in one go.
//   meeting_transcriber_test <clip.wav> [<clip.wav> ...]    (16 kHz mono clips to join; Whisper part skipped if none)
// Exit code: 0 = all PASS.

@main struct MeetingTranscriberTest {
    static var failed = 0
    static func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL")  \(name)"); if !ok { failed += 1 } }
    static let sr = 16_000

    /// Fake "speech": a loud tone. Fake "silence": zeros. The fake gate says speech where the chunk is loud.
    static func tone(_ sec: Double) -> [Float] { (0..<Int(sec * Double(sr))).map { 0.3 * sin(Float($0) * 0.2) } }
    static func quiet(_ sec: Double) -> [Float] { [Float](repeating: 0, count: Int(sec * Double(sr))) }
    static let fakeGate: ([Float]) -> Bool = { x in x.contains { abs($0) > 0.1 } }

    actor Log { var sizes: [Int] = []; var n = 0
        func record(_ c: Int) -> Int { sizes.append(c); n += 1; return n } }

    static func main() async {
        await fakeTests()
        echoTests()
        if CommandLine.arguments.count > 1 { await whisperTest(Array(CommandLine.arguments.dropFirst())) }
        else { print("SKIP  Whisper run (no clips given)") }
        print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: fake transcriber

    static func fakeTests() async {
        // 1. Cut lands in the quiet gap near 30 s; start times are right; both sides kept apart.
        //    "them": 27 s talking, 1.5 s gap, 26.5 s talking (55 s). "you": silent the whole time.
        let log = Log()
        let t = MeetingTranscriber(transcribe: { s in
            let n = await log.record(s.count)
            return "Chunk \(n) first sentence here. Chunk \(n) second sentence here."
        }, hasSpeech: fakeGate)
        let them = tone(27) + quiet(1.5) + tone(26.5)
        var lines: [TranscriptLine] = []
        var i = 0
        while i < them.count {   // fed one second at a time, like the recorder
            let end = min(i + sr, them.count)
            lines += await t.add(you: quiet(Double(end - i) / Double(sr)), them: Array(them[i..<end]))
            i = end
        }
        check(lines.count == 2 && lines.allSatisfy { $0.speaker == .them }, "first 30 s chunk gives 2 lines, all 'them'; silent 'you' gives none (\(lines.count))")
        let first = await log.sizes.first ?? 0
        let cutSec = Double(first) / Double(sr)
        check(cutSec > 27 && cutSec < 28.5, String(format: "cut lands in the quiet gap (at %.2f s, gap is 27.0-28.5)", cutSec))
        let rest = await t.finish()
        check(rest.count == 2, "finish() flushes the rest as 2 more lines (\(rest.count))")
        check(abs((rest.first?.start ?? 0) - cutSec) < 0.01, String(format: "second chunk starts where the first ended (%.2f s)", rest.first?.start ?? -1))
        let all = lines + rest
        check(zip(all, all.dropFirst()).allSatisfy { $0.start < $1.start }, "start times strictly increase")
        check(all[1].start > all[0].start + 3 && all[1].start < cutSec, "lines in a chunk share out its time (\(all.map { String(format: "%.1f", $0.start) }))")
        let sizes = await log.sizes
        check(sizes.reduce(0, +) <= them.count && Double(them.count - sizes.reduce(0, +)) / Double(sr) < 0.01, "every sample of 'them' was transcribed once")

        // 2. Both sides at once, told apart by the sign of the signal (You is above zero, Them below).
        let t2 = MeetingTranscriber(transcribe: { s in (s.reduce(0, +) > 0) ? "I say this today." : "They say that today." }, hasSpeech: fakeGate)
        let a = await t2.add(you: tone(31).map { $0 + 0.4 }, them: tone(31).map { $0 - 0.4 })
        check(a.count == 2 && Set(a.map { $0.speaker }) == [.you, .them], "both sides transcribed in the same call")
        check(a.allSatisfy { ($0.speaker == .you) == ($0.text == "I say this today.") }, "each speaker gets the text of its own audio")
        check(zip(a, a.dropFirst()).allSatisfy { $0.start <= $1.start }, "output sorted by time")

        // 3. A chunk that is all silence makes no line and does not call the transcriber.
        let log3 = Log()
        let t3 = MeetingTranscriber(transcribe: { s in _ = await log3.record(s.count); return "Hello there friend." }, hasSpeech: fakeGate)
        let b = await t3.add(you: quiet(31), them: quiet(31))
        let c = await t3.finish()
        let calls3 = await log3.n
        check(b.isEmpty && c.isEmpty && calls3 == 0, "silent audio: no lines, no transcriber calls")

        // 3b. Lines start when the person actually spoke, and two turns in one chunk stay two lines.
        //     (Found by the end-to-end test: a chunk that was 6 s of silence, then talk, was stamped 0:00.)
        let log3b = Log()
        let t3b = MeetingTranscriber(transcribe: { s in let n = await log3b.record(s.count); return "Turn \(n) words here." },
                                     hasSpeech: fakeGate)
        let late = await t3b.add(you: quiet(31), them: quiet(6) + tone(3) + quiet(2.5) + tone(4) + quiet(15.5))
        let lateStarts = late.map { String(format: "%.1f", $0.start) }
        check(late.count == 2, "two turns separated by a pause give two lines (\(late.count))")
        check(abs((late.first?.start ?? -1) - 6) < 0.3, "first line starts when they started talking, about 6 s (\(lateStarts))")
        check(late.count == 2 && abs(late[1].start - 11.5) < 0.3, "second turn starts about 11.5 s (\(lateStarts))")
        let regions = MeetingTranscriber.speechRegions(in: tone(5))
        check(regions == [0..<tone(5).count], "steady sound throughout: the whole chunk is kept")

        // 4. Transcriber throws or returns nothing: no lines, meeting carries on.
        struct Boom: Error {}
        let t4 = MeetingTranscriber(transcribe: { _ in throw Boom() }, hasSpeech: fakeGate)
        let d = await t4.add(you: tone(31), them: quiet(31))
        check(d.count == 1 && d[0].text == MeetingTranscriber.notTranscribed && d[0].speaker == .you && d[0].start == 0,
              "a failing transcribe leaves one '(audio not transcribed)' line at the chunk's start")
        let failedN = await t4.failedChunks
        check(failedN == 1, "failed chunks are counted")
        let d2 = await t4.add(you: tone(31), them: quiet(31))
        check(d2.count == 1 && d2[0].start > 25, "meeting carries on after a failure (next marker at \(d2.first?.start ?? -1) s)")
        let t5 = MeetingTranscriber(transcribe: { _ in "  " }, hasSpeech: fakeGate)
        check((await t5.add(you: tone(31), them: quiet(31))).isEmpty, "empty text gives no lines")

        // 4b. Overlapping calls with a slow transcriber: never two transcriptions at once, nothing lost or repeated.
        actor Gauge { var now = 0, peak = 0, done = 0, samples = 0
            func enter() { now += 1; peak = max(peak, now) }
            func leave(_ n: Int) { now -= 1; done += 1; samples += n } }
        let g = Gauge()
        let slow = MeetingTranscriber(transcribe: { s in
            await g.enter(); try await Task.sleep(nanoseconds: 80_000_000); await g.leave(s.count)
            return "Slow words one. Slow words two."
        }, hasSpeech: fakeGate)
        let feeds = 4
        let firstCall = Task { await slow.add(you: tone(31), them: quiet(31)) }
        let inputs = Task { () -> [[TranscriptLine]] in
            var r: [[TranscriptLine]] = []
            await withTaskGroup(of: [TranscriptLine].self) { grp in
                for _ in 1..<feeds { grp.addTask { await slow.add(you: tone(31), them: quiet(31)) } }
                for await x in grp { r.append(x) }
            }
            return r
        }
        try? await Task.sleep(nanoseconds: 20_000_000)   // the first chunk is still being transcribed
        let fin = await slow.finish()                     // must wait for it and for the queued calls
        let doneAtFinish = await g.done
        let outs = [await firstCall.value] + (await inputs.value) + [fin]
        let allLines = outs.flatMap { $0 }
        let peak = await g.peak
        check(peak == 1, "overlapping add()/finish(): never more than one transcription at a time (peak \(peak))")
        check(outs.allSatisfy { o in zip(o, o.dropFirst()).allSatisfy { $0.start <= $1.start } }, "overlapping calls: each result sorted by time")
        let used = await g.samples
        check(used == feeds * 31 * sr && Set(allLines.map { $0.start }).count == allLines.count,
              "overlapping calls: all \(feeds * 31) s transcribed once, no repeats (\(allLines.count) lines)")
        let left = await slow.bufferedSeconds.you
        check(doneAtFinish > 0 && left == 0, "finish() waited for in-flight work and leaves nothing buffered (\(doneAtFinish) chunks done when it returned)")

        // 5. Memory: a 2-hour meeting fed 1 s at a time never holds more than ~35 s per side, and times stay right.
        let t6 = MeetingTranscriber(transcribe: { _ in "Some words were said." }, hasSpeech: fakeGate)
        let sec = tone(1)
        var maxBuf = 0.0, count = 0, lastStart = 0.0
        for _ in 0..<7200 {
            let out = await t6.add(you: sec, them: sec)
            count += out.count
            lastStart = max(lastStart, out.map { $0.start }.max() ?? 0)
            let b = await t6.bufferedSeconds
            maxBuf = max(maxBuf, b.you, b.them)
        }
        count += (await t6.finish()).count
        check(maxBuf <= 31, String(format: "2-hour meeting: most audio ever held per side = %.1f s", maxBuf))
        check(count >= 2 * 7200 / 31 && lastStart > 7000, "2-hour meeting: \(count) lines, last chunk starts at \(Int(lastStart)) s")

        // 6. Sentence splitting.
        let s1 = MeetingTranscriber.splitSentences("The rate is 6.5 percent today. Can you send it? Yes. We lock Friday!")
        check(s1 == ["The rate is 6.5 percent today.", "Can you send it? Yes.", "We lock Friday!"], "sentences: keeps 6.5, joins one-word 'Yes.' (\(s1))")
        check(MeetingTranscriber.splitSentences("   ").isEmpty, "blank text has no sentences")
    }

    // MARK: echoes

    static func echoTests() {
        func L(_ s: Speaker, _ t: Double, _ x: String) -> TranscriptLine { TranscriptLine(speaker: s, start: t, text: x) }
        let lines = [
            L(.them, 10, "We can lock the rate at six point five percent on Friday."),
            L(.you,  11, "We can lock the rate at six point five percent on friday"),             // echo (punctuation, case)
            L(.you,  14, "Sounds good, please send me the lock confirmation by email."),       // real reply
            L(.them, 20, "Your closing costs will be around eight thousand dollars."),
            L(.you,  21, "Your closing cost will be around eight thousand dollars"),            // echo, small differences
            L(.you,  24, "Okay."),                                                              // short reply kept
            L(.you,  90, "We can lock the rate at six point five percent on Friday."),          // same words, far away in time: kept
            L(.them, 100, "Great, talk to you soon."),
        ]
        let out = MeetingTranscriber.removeEchoes(lines)
        check(out.count == 6, "echoes: 2 of 8 lines dropped (\(out.count) left)")
        check(!out.contains { $0.start == 11 || $0.start == 21 }, "echoes: the two repeats are the ones dropped")
        check(out.contains { $0.start == 14 } && out.contains { $0.start == 24 } && out.contains { $0.start == 90 }, "echoes: real reply, short 'Okay.', and distant repeat kept")
        check(out.filter { $0.speaker == .them }.count == 3, "echoes: 'them' lines never dropped")
        check(zip(out, out.dropFirst()).allSatisfy { $0.start <= $1.start }, "echoes: order kept")
        check(MeetingTranscriber.removeEchoes([]).isEmpty, "echoes: empty in, empty out")
        // Stop-word-heavy genuine reply, and a number read-back in different words, both survive.
        let hard = [L(.them, 30, "We need to think about what the closing date is."),
                    L(.you, 32, "I think that is what we need to do."),
                    L(.them, 60, "Your payment will be two thousand four hundred and fifty dollars a month."),
                    L(.you, 63, "So two thousand four hundred fifty dollars a month, right?")]
        check(MeetingTranscriber.removeEchoes(hard).count == 4, "echoes: stop-word reply and rephrased number read-back are kept")
        // Spread across two neighbouring Them lines still counts as an echo.
        let split = [L(.them, 40, "The appraisal is done."), L(.them, 42, "It came in at four fifty."),
                     L(.you, 41, "The appraisal is done it came in at four fifty")]
        check(MeetingTranscriber.removeEchoes(split).count == 2, "echoes: copy of two neighbouring lines is dropped")
        // Replies that quote a few of their words are not echoes.
        let quote = [L(.them, 5, "The appraisal came in at four hundred and fifty thousand."),
                     L(.you, 7, "Okay so the appraisal is fine, what happens next with underwriting?")]
        check(MeetingTranscriber.removeEchoes(quote).count == 2, "echoes: a reply that reuses a few words is kept")
    }

    // MARK: real Whisper

    static func load(_ path: String) -> [Float] {
        let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try! file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    static func words(_ s: String) -> [String] { MeetingTranscriber.normalizedWords(s) }

    /// Word-level edit distance (substitutions, insertions, deletions).
    static func wordDistance(_ a: [String], _ b: [String]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return a.isEmpty ? b.count : prev[b.count]
    }

    static func whisperTest(_ clips: [String]) async {
        // Join the clips (1.2 s of room-quiet between them) until there are at least 180 s.
        let samples = clips.map(load)
        var rec: [Float] = []
        var k = 0
        while Double(rec.count) / Double(sr) < 180 { rec += samples[k % samples.count] + quiet(1.2); k += 1 }
        let secs = Double(rec.count) / Double(sr)
        print(String(format: "recording: %d clips joined, %.1f s", k, secs))

        let engine = WhisperEngine()
        // Reference: each clip on its own, in one pass (the way Whisper does best), through SpeechGate like the app.
        let t0 = Date()
        var refs: [String] = []
        for c in samples {
            refs.append((try? await engine.transcribe(samples: SpeechGate.process(c).samples, sampleRate: 16_000)) ?? "")
        }
        let singleSecs = Date().timeIntervalSince(t0)
        // For information only: the whole 3 minutes handed to Whisper in one go (it is known to drift on long audio).
        let wholeText = (try? await engine.transcribe(samples: SpeechGate.process(rec).samples, sampleRate: 16_000)) ?? ""

        let t1 = Date()
        let tr = MeetingTranscriber(transcribe: { try await engine.transcribe(samples: $0, sampleRate: 16_000) })
        var lines: [TranscriptLine] = []
        var i = 0
        while i < rec.count {   // 'them' = the recording, 'you' = silence, one second at a time
            let end = min(i + sr, rec.count)
            lines += await tr.add(you: quiet(Double(end - i) / Double(sr)), them: Array(rec[i..<end]))
            i = end
        }
        lines += await tr.finish()
        let chunkSecs = Date().timeIntervalSince(t1)
        engine.unload()

        // the recording cycles through the clips k times, so the reference does too
        let cycles = (0..<k).map { refs[$0 % refs.count] }.joined(separator: " ")
        let chunked = lines.map { $0.text }.joined(separator: " ")
        let a = words(cycles), b = words(chunked)
        let dist = wordDistance(a, b)
        let pct = 100.0 * Double(dist) / Double(max(a.count, 1))
        print("reference (clip by clip): \(a.count) words (\(String(format: "%.1f", singleSecs)) s)   chunked: \(b.count) words in \(lines.count) lines (\(String(format: "%.1f", chunkSecs)) s)")
        print(String(format: "word differences between the two: %d (%.1f%% of the reference words)", dist, pct))
        let whole = words(wholeText)
        print("for information: whole 3 minutes in one go gave \(whole.count) words, \(wordDistance(a, whole)) differ from the reference")
        if pct >= 5 { print("reference: \(cycles)\nchunked: \(chunked)") }
        check(a.count > 100, "reference run produced text")
        check(pct < 5, String(format: "chunked words match clip-by-clip Whisper within 5%% (%.1f%%)", pct))
        check(lines.allSatisfy { $0.speaker == .them } && !lines.isEmpty, "all lines are 'them' (the silent 'you' side made none)")
        check(zip(lines, lines.dropFirst()).allSatisfy { $0.start <= $1.start } && (lines.first?.start ?? 99) < 5 && (lines.last?.start ?? 0) < secs,
              "line times increase from the start and stay inside the recording (first \(String(format: "%.1f", lines.first?.start ?? -1)) s, last \(String(format: "%.1f", lines.last?.start ?? -1)) s)")
        // Where a known sentence sits in the audio vs. where the line says it is.
        if let probe = lines.first(where: { $0.text.lowercased().contains("rate lock deadline") || $0.text.lowercased().contains("thursday is the rate") }) {
            print(String(format: "timing example: \"%@\" reported at %.1f s", probe.text, probe.start))
        }
    }
}
