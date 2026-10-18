import Foundation
import AVFoundation

// Meeting notetaker end-to-end, minus the live audio capture: a two-person mortgage meeting (two `say` voices, one
// file per side) is fed to MeetingTranscriber in 3-second pieces the way MeetingNotes does, with real Whisper. Then
// MeetingSummarizer writes the note, MeetingStore saves it to a temp folder, and it's loaded back.
//   meeting_pipeline_test <dir with you1/them1/you2/them2.wav>

@main
enum MeetingPipelineTest {
    static var failed = 0
    static func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL")  \(name)"); if !ok { failed += 1 } }

    static func load(_ path: String) -> [Float] {
        let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try! file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    static func main() async {
        let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/meeting"
        let sr = 16_000
        let gap = [Float](repeating: 0, count: sr)   // 1 s between turns
        // Lay the turns out on one timeline: each side gets its own speech and silence while the other talks.
        var you: [Float] = [], them: [Float] = []
        for (file, isYou) in [("you1", true), ("them1", false), ("you2", true), ("them2", false)] {
            let clip = load("\(dir)/\(file).wav") + gap
            let quiet = [Float](repeating: 0, count: clip.count)
            you += isYou ? clip : quiet
            them += isYou ? quiet : clip
        }

        let engine = WhisperEngine()
        let transcriber = MeetingTranscriber { try await engine.transcribe(samples: $0, sampleRate: 16_000) }
        var lines: [TranscriptLine] = []
        let step = 3 * sr
        var i = 0
        while i < you.count {
            let j = min(i + step, you.count)
            lines += await transcriber.add(you: Array(you[i..<j]), them: Array(them[i..<j]))
            i = j
        }
        lines += await transcriber.finish()
        lines.sort { $0.start < $1.start }
        engine.unload()
        for l in lines { print(String(format: "  [%5.1f] %@: %@", l.start, l.speaker.rawValue, l.text)) }

        let all = lines.map(\.text).joined(separator: " ").lowercased()
        check(lines.contains { $0.speaker == .you } && lines.contains { $0.speaker == .them }, "both You and Them lines")
        check(zip(lines, lines.dropFirst()).allSatisfy { $0.start <= $1.start }, "lines in time order")
        check(all.contains("pay stub"), "your words reached the transcript (pay stubs)")
        check(all.contains("425") || all.contains("four hundred"), "their words reached the transcript (425)")
        let firstThem = lines.first { $0.speaker == .them }?.start ?? 0
        let youSeconds = Double(load("\(dir)/you1.wav").count + sr) / Double(sr)
        check(abs(firstThem - youSeconds) < 3, String(format: "Them's first line starts near %.1f s (got %.1f)", youSeconds, firstThem))

        let summarizer = MeetingSummarizer()
        guard summarizer.isAvailable else {
            print("SKIPPED (model unavailable): summary part")
            exit(failed == 0 ? 0 : 1)
        }
        let note = await summarizer.summarize(lines, appName: "FaceTime", date: Date(timeIntervalSince1970: 1_792_000_000),
                                              duration: Double(you.count) / Double(sr), loanDetails: true)
        print("  title: \(note.title)\n  overview: \(note.overview)")
        for d in note.loanDetails { print("  detail: \(d.label): \(d.value)") }
        for t in note.todos { print("  todo: \(t.owner.rawValue): \(t.task)") }
        check(!note.overview.isEmpty, "overview written")
        check(!note.todos.isEmpty, "to-dos found")
        typealias C = MeetingSummarizer.Checks
        check(C.isTopicTitle(note.title), "title is a short topic, not a cut-off sentence (\(note.title))")
        check(!C.hasFirstPerson(note.overview), "overview says 'you', not 'I'")
        check(C.sentences(note.overview).allSatisfy { C.unbackedClaims(in: $0, lines: C.spokenLines(lines)).isEmpty },
              "overview makes no qualify/approve claim that wasn't said")
        check(note.todos.contains { $0.owner == .them && $0.task.lowercased().contains("pay stub") }, "pay stubs are a Them to-do")
        check(!note.todos.contains { $0.owner == .you && $0.task.lowercased().contains("pay stub") }, "pay stubs aren't a You to-do")
        check(!note.todos.contains { $0.task.lowercased().contains("january") || $0.task.lowercased().contains("would like") },
              "'we'd like to close by January' isn't a to-do")
        check(note.todos.contains { $0.owner == .you && $0.task.lowercased().contains("checklist") }, "sending the checklist is a You to-do")
        check(!note.todos.contains { $0.owner == .them && $0.task.lowercased().contains("checklist") }, "the checklist isn't also a Them to-do")
        let digits = Set(all.filter(\.isNumber).map(String.init))
        check(note.loanDetails.allSatisfy { d in d.value.filter(\.isNumber).allSatisfy { digits.contains(String($0)) } },
              "loan-detail digits all appear in the transcript")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("verbaline-pipeline-\(getpid())")
        let store = MeetingStore(folder: folder)
        do {
            let url = try store.save(note, gaps: summarizer.lastGaps)
            let back = store.load(url)
            check(back?.title == note.title && back?.transcript.count == note.transcript.count, "saved note loads back")
            check(store.list().count == 1, "note listed")
        } catch {
            check(false, "save note: \(error)")
        }
        try? FileManager.default.removeItem(at: folder)
        exit(failed == 0 ? 0 : 1)
    }
}
