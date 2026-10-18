// MeetingSummarizer.swift
// Piece 3 of the meeting notetaker: turns a transcript into a note, answers questions about it, and keeps the
// notes as Markdown files.
//
//  1. MeetingSummarizer  - Apple's on-device model (FoundationModels, macOS 26+). Nothing leaves the Mac.
//                          summarize(...) -> MeetingNote: title, overview (a 2–3 minute read), to-dos with an
//                          owner, loan details. answer(_:from:) -> a short answer from the transcript, or a plain
//                          "couldn't find that" — never a guess.
//  2. MeetingStore       - save / list / load notes in ~/Documents/Verbaline Notes/ ("2026-10-17 1402 <title>.md").
//
// The model's context window, measured 2026-10-17 on macOS 26.6.2 (SystemLanguageModel.contextSize): 4,096 tokens
// for instructions + prompt + answer together. Meeting talk runs ~0.77 words per token (1,560 words = 2,010 tokens),
// and a prompt of 3,315 words failed with exceededContextWindowSize. So one call can read at most ~3,000 words;
// we send ≤ 1,400 words of transcript per call to leave room for the instructions and a long answer, and
// summarise longer meetings in pieces, then combine the pieces.
//
// Safety rails, because notes may cover mortgage details (a regulated industry):
//  - every number in a loan detail, to-do, overview sentence or answer must appear in the transcript
//    ("$450k" matches "450,000"; "20%" matches "twenty percent"); a loan detail or to-do with a number that
//    doesn't is dropped, an overview sentence with one is removed, an answer with one becomes "couldn't find that";
//  - loan details are only what was actually said: price, amounts, income and rate must contain a number;
//  - a to-do or loan detail whose words mostly weren't said in the meeting is dropped;
//  - regulated words (qualify, approve, eligible, lock, guarantee, afford, recommend…) and judgments ("a good rate")
//    only where the meeting used them, next to the same number: "the loan amount would be $340,000" must not become
//    "they would qualify for $340,000" — such a sentence, to-do, loan detail or answer is dropped (unbackedClaims);
//  - to-dos are checked against what was said: the owner is whoever will do it ("please send me your pay stubs"
//    is the clients'), wishes aren't to-dos ("we'd like to close by January"), and a task no one asked for or
//    promised ("send car payment" from "one car payment") is dropped;
//  - house style: the overview speaks to the officer as "you" (a first-person "Maria and I…" is rewritten),
//    says each point once (a long meeting's pieces repeat), and the title is a short topic, never a cut sentence;
//  - greedy sampling (same transcript → same note) and a time limit on every model call;
//  - plain-text replies in a simple line format, not guided generation: a schema was refused on every mortgage
//    meeting tried (see Engine).
//
// Public surface: MeetingSummarizer.init / isAvailable / summarize(...) / answer(_:from:), MeetingStore.
// `MeetingSummarizer.Checks` is internal plumbing the test reaches into.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Public API

final class MeetingSummarizer: @unchecked Sendable {

    /// Measured, see the top of the file.
    static let contextTokens = 4096
    static let wordsPerToken = 0.77
    /// Transcript words sent in one model call (≈ 1,820 tokens), leaving room for instructions and the answer.
    static let wordsPerPiece = 1400
    /// Time limit for one model call. A long overview takes ~10–20 s; anything past this is stuck.
    static let callTimeout: Double = 120

    static let notFound = "I couldn't find that in the meeting transcript."
    static let unavailableAnswer = "Apple Intelligence isn't available on this Mac, so I can't answer questions about the meeting yet."

    private var engineBox: AnyObject?          // Engine on macOS 26+, nil otherwise
    /// What happened on the last call, for tests and logs ("3 pieces, 1 loan detail dropped").
    private(set) var lastDiagnostic = "not used yet"
    /// Sections of the last summarize() that are missing parts because a model call failed (not because nothing was
    /// said). Pass to MeetingStore.save so the note says "this list may be incomplete" instead of "No to-dos".
    private(set) var lastGaps: Gaps = []

    struct Gaps: OptionSet, Equatable {
        let rawValue: Int
        static let overview = Gaps(rawValue: 1)
        static let todos = Gaps(rawValue: 2)
        static let loanDetails = Gaps(rawValue: 4)
        static let incompleteNote = "Some parts of this meeting couldn't be read, so this list may be incomplete."
        static let incompleteOverview = "Some parts of this meeting couldn't be read, so this overview may be incomplete."
    }

    init() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { engineBox = Engine() }
        #endif
    }

    /// true if Apple's on-device model is ready on this Mac.
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let e = engineBox as? Engine { return e.model.isAvailable }
        #endif
        return false
    }

    /// Writes the note for a finished meeting. Never throws: if the model is missing or fails, the note still has
    /// the transcript and an overview that says what went wrong.
    func summarize(_ lines: [TranscriptLine], appName: String, date: Date, duration: TimeInterval, loanDetails: Bool) async -> MeetingNote {
        var note = MeetingNote(title: "Meeting on \(appName)", date: date, duration: duration, appName: appName,
                               overview: "", todos: [], loanDetails: [], transcript: lines)
        let spoken = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !spoken.isEmpty else {
            note.overview = "Nobody said anything that Verbaline could hear in this meeting, so there's nothing to sum up."
            lastDiagnostic = "empty transcript"; lastGaps = []
            return note
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let engine = engineBox as? Engine, engine.model.isAvailable {
            let (n, diag, gaps) = await engine.summarize(spoken, into: note, loanDetails: loanDetails)
            lastDiagnostic = diag; lastGaps = gaps
            return n
        }
        #endif
        note.overview = "Verbaline couldn't write an overview because Apple Intelligence isn't available on this Mac. The full transcript is below."
        lastDiagnostic = "model unavailable"; lastGaps = loanDetails ? [.overview, .todos, .loanDetails] : [.overview, .todos]
        return note
    }

    /// Answers a question from the transcript so far. Says plainly when the answer isn't there.
    func answer(_ question: String, from lines: [TranscriptLine]) async -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "Type a question about the meeting." }
        let spoken = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !spoken.isEmpty else { return "Nothing has been said in the meeting yet." }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let engine = engineBox as? Engine, engine.model.isAvailable {
            let (a, diag) = await engine.answer(q, from: spoken)
            lastDiagnostic = diag
            return a
        }
        #endif
        lastDiagnostic = "model unavailable"
        return Self.unavailableAnswer
    }
}

// MARK: - Checks (pure text helpers; no model)

extension MeetingSummarizer {

    enum Checks {

        // Loan detail labels, in the order they're shown. `needsNumber`: a value without a number isn't a real answer.
        static let loanFields: [(key: String, label: String, needsNumber: Bool)] = [
            ("purpose", "Purpose", false),
            ("purchasePrice", "Purchase price", true),
            ("loanAmount", "Loan amount", true),
            ("downPayment", "Down payment", true),
            ("income", "Income", true),
            ("rate", "Rate", true),
            ("timeline", "Timeline", false),
            ("documents", "Documents needed", false),
            ("followUp", "Follow-up date", false),
        ]

        /// "You: text" lines, as the model reads them.
        static func render(_ lines: [TranscriptLine]) -> String {
            lines.map { "\(speakerName($0.speaker)): \(oneLine($0.text))" }.joined(separator: "\n")
        }

        static func speakerName(_ s: Speaker) -> String { s == .you ? "You" : "Them" }

        static func oneLine(_ s: String) -> String {
            s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
        }

        static func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

        /// Consecutive runs of lines of at most `maxWords` words each (a single longer line gets a piece of its own).
        static func pieces(_ lines: [TranscriptLine], maxWords: Int) -> [[TranscriptLine]] {
            var out: [[TranscriptLine]] = []
            var cur: [TranscriptLine] = []
            var words = 0
            for l in lines {
                let w = wordCount(l.text) + 1
                if !cur.isEmpty && words + w > maxWords { out.append(cur); cur = []; words = 0 }
                cur.append(l); words += w
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        }

        // MARK: numbers

        private static let digitRX = try! NSRegularExpression(
            pattern: "\\d+(?:[.,]\\d+)*(?:\\s?(k|thousand|m|mil|million|b|bn|billion)(?![\\p{L}]))?",
            options: .caseInsensitive)

        private static let units: [String: Double] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
            "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
            "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        ]
        private static let scales: [String: Double] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
        private static let ordinals: [String: Double] = [
            "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
            "ninth": 9, "tenth": 10, "twelfth": 12, "fifteenth": 15, "twentieth": 20, "thirtieth": 30,
        ]

        /// Every number in `s` as a value: "$450,000" → 450000, "450k" → 450000, "1.2 million" → 1200000,
        /// "6.75%" → 6.75, "ninety thousand" → 90000. Written-out ordinals count too ("the fifth" → 5).
        static func numbers(in s: String) -> [Double] {
            var out: [Double] = []
            let ns = s as NSString
            for m in digitRX.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let whole = ns.substring(with: m.range)
                let digits = whole.prefix(while: { $0.isNumber || $0 == "." || $0 == "," })
                // "1,200" is a thousands comma; "1,5" is not something people write in English, treat as 15.
                guard var v = Double(digits.replacingOccurrences(of: ",", with: "")) else { continue }
                if m.range(at: 1).location != NSNotFound {
                    switch ns.substring(with: m.range(at: 1)).lowercased() {
                    case "k", "thousand": v *= 1_000
                    case "m", "mil", "million": v *= 1_000_000
                    default: v *= 1_000_000_000
                    }
                }
                out.append(v)
            }
            // Spelled-out numbers: "ninety thousand", "twenty five", "two".
            var total = 0.0, current = 0.0, inNumber = false
            func flush() { if inNumber { out.append(total + current) }; total = 0; current = 0; inNumber = false }
            for raw in s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }) {
                for w in raw.split(separator: "-").map(String.init) {
                    if let u = units[w] { current += u; inNumber = true }
                    else if let sc = scales[w], inNumber || w == "hundred" {
                        if current == 0 { current = 1 }
                        if sc == 100 { current *= 100 } else { total += current * sc; current = 0 }
                        inNumber = true
                    } else if let o = ordinals[w] { flush(); out.append(o) }
                    else if w == "and" && inNumber { continue }
                    else { flush() }
                }
            }
            flush()
            return out
        }

        /// The values a note may use: every number in the transcript, plus each digit run without its multiplier
        /// ("450 thousand" allows 450000 and 450), so a faithful copy always passes.
        static func knownNumbers(in text: String) -> Set<Double> {
            var known = Set(numbers(in: text).map(rounded))
            let ns = text as NSString
            for m in digitRX.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let digits = ns.substring(with: m.range).prefix(while: { $0.isNumber || $0 == "." || $0 == "," })
                if let v = Double(digits.replacingOccurrences(of: ",", with: "")) { known.insert(rounded(v)) }
            }
            return known
        }

        private static func rounded(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

        /// Numbers in `s` that never appear in the transcript (empty = safe).
        static func unknownNumbers(in s: String, known: Set<Double>) -> [Double] {
            numbers(in: s).map(rounded).filter { !known.contains($0) }
        }

        /// Removes overview sentences that use a number the transcript doesn't have.
        static func dropSentencesWithUnknownNumbers(_ text: String, known: Set<Double>) -> (String, Int) {
            var dropped = 0
            let paragraphs = text.components(separatedBy: "\n").map { para -> String in
                var kept: [String] = []
                para.enumerateSubstrings(in: para.startIndex..., options: .bySentences) { sub, _, _, _ in
                    guard let sub else { return }
                    if unknownNumbers(in: sub, known: known).isEmpty { kept.append(sub) } else { dropped += 1 }
                }
                return kept.joined().trimmingCharacters(in: .whitespaces)
            }
            var out = paragraphs.joined(separator: "\n")
            while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
            return (out.trimmingCharacters(in: .whitespacesAndNewlines), dropped)
        }

        /// Cuts a last sentence the model didn't finish (it ran out of room): "... rates move every day and" → "...".
        /// A sentence ends at . ! ? followed by a space or the end — never a decimal point ("6.75").
        static func dropUnfinishedEnding(_ text: String) -> String {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = t.last, !".!?\"”)".contains(last) else { return t }
            var end: String.Index?
            var i = t.startIndex
            while i < t.endIndex {
                let next = t.index(after: i)
                if ".!?".contains(t[i]), next == t.endIndex || t[next].isWhitespace || "\"”)".contains(t[next]) {
                    end = (next < t.endIndex && "\"”)".contains(t[next])) ? next : i
                }
                i = next
            }
            guard let end else { return t }
            return String(t[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// "call" the noun → "meeting" ("on the call", "this phone call", "the calls"); "call" the verb stays
        /// ("I'll call you Monday", "give you a call").
        static func meetingNotCall(_ s: String) -> String {
            var out = s.replacingOccurrences(of: "\\b(?:phone|video|conference|zoom|facetime) call\\b", with: "meeting",
                                             options: [.regularExpression, .caseInsensitive])
            out = out.replacingOccurrences(of: "\\b(the|this|that|our|today's|yesterday's|last|next|first|follow-up) call\\b",
                                           with: "$1 meeting", options: [.regularExpression, .caseInsensitive])
            out = out.replacingOccurrences(of: "\\b(the|these|those|our|both|two|several) calls\\b",
                                           with: "$1 meetings", options: [.regularExpression, .caseInsensitive])
            return out
        }

        // MARK: loan details

        /// Keeps a loan detail only if it's a real answer and every number in it was said in the meeting.
        static func acceptLoanValue(_ value: String, needsNumber: Bool, known: Set<Double>, transcript: String) -> String? {
            var v = oneLine(value).trimmingCharacters(in: CharacterSet(charactersIn: " .;\"'"))
            guard !v.isEmpty else { return nil }
            let lower = v.lowercased()
            let empties = ["none", "n/a", "na", "not mentioned", "not said", "not discussed", "unknown", "empty", "nil", "null",
                           "not specified", "not stated", "not provided", "no", "-", "tbd"]
            if empties.contains(lower) || lower.hasPrefix("not ") || (lower.hasPrefix("no ") && needsNumber) { return nil }
            let nums = numbers(in: v)
            if needsNumber && nums.isEmpty { return nil }
            if !unknownNumbers(in: v, known: known).isEmpty { return nil }
            if !mostlySaid(v, in: transcript) { return nil }
            if !unbackedClaims(in: v, lines: transcript.components(separatedBy: "\n")).isEmpty { return nil }
            if v.count > 240 { v = String(v.prefix(237)) + "…" }
            return v.prefix(1).uppercased() + v.dropFirst()
        }

        /// Most of the text's words (4+ letters) come from the meeting, so a made-up phrase (or an example from the
        /// instructions) can't slip through. Shared 4-letter stems count ("uploading" / "upload").
        static func mostlySaid(_ text: String, in transcript: String) -> Bool {
            let vocab = Set(words(transcript))
            let stems = Set(vocab.filter { $0.count >= 4 }.map { String($0.prefix(4)) })
            let content = words(text).filter { $0.count >= 4 }
            guard !content.isEmpty else { return true }
            let hits = content.filter { vocab.contains($0) || stems.contains(String($0.prefix(4))) }
            return Double(hits.count) >= Double(content.count) * 0.5
        }

        /// Keeps a to-do if it has text and no invented number. Trims "You will"/"I'll" lead-ins.
        static func acceptTodo(_ task: String, known: Set<Double>, transcript: String? = nil) -> String? {
            var t = oneLine(task).trimmingCharacters(in: CharacterSet(charactersIn: " .;-•*\"'"))
            for lead in ["you will ", "you'll ", "they will ", "they'll ", "i will ", "i'll ", "we will ", "we'll ", "to "] where t.lowercased().hasPrefix(lead) {
                t = String(t.dropFirst(lead.count))
            }
            guard t.count >= 3, unknownNumbers(in: t, known: known).isEmpty else { return nil }
            if let transcript, !mostlySaid(t, in: transcript) { return nil }
            return t.prefix(1).uppercased() + t.dropFirst()
        }

        /// Bullets, numbering and bold the model sometimes adds: "1. **You:** Send" → "You: Send".
        private static func bare(_ line: String) -> String {
            var l = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .trimmingCharacters(in: .whitespaces)
            l = l.replacingOccurrences(of: "^(?:[-•*]|\\d+[.)]|\\[ ?x?\\])\\s*", with: "", options: .regularExpression)
            return l.trimmingCharacters(in: .whitespaces)
        }

        /// Reads "You: task" / "Them: task" lines. Returns the accepted to-dos and how many were dropped.
        static func parseTodos(_ reply: String, known: Set<Double>, transcript: String? = nil) -> ([MeetingTodo], Int) {
            var out: [MeetingTodo] = []
            var dropped = 0
            for raw in reply.components(separatedBy: .newlines) {
                let l = bare(raw)
                guard let colon = l.firstIndex(of: ":") else { continue }
                let who = l[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                let owner: Speaker
                if ["you", "loan officer", "the loan officer"].contains(who) { owner = .you }
                else if ["them", "clients", "the clients", "client", "they"].contains(who) { owner = .them }
                else { continue }
                let said = transcript.map { $0.components(separatedBy: "\n") }
                guard let (who, fixed) = fixTodo(owner: owner, task: String(l[l.index(after: colon)...])),
                      let t = acceptTodo(fixed, known: known, transcript: transcript),
                      said.map({ unbackedClaims(in: t, lines: $0).isEmpty }) ?? true else { dropped += 1; continue }
                // Who does it, from what was said, beats the model's label (it tends to copy the speaker label).
                var doer = who
                if let transcript {
                    let src = source(of: t, in: transcript)
                    guard src.matched else { dropped += 1; continue }
                    if let o = src.owner { doer = o }
                }
                out.append(MeetingTodo(owner: doer, task: t))
            }
            return (out, dropped)
        }

        /// Reads "Label: value" lines for the known labels. Returns [key: value] and how many were dropped.
        static func parseLoanDetails(_ reply: String, known: Set<Double>, transcript: String) -> ([(String, String)], Int) {
            var out: [(String, String)] = []
            var dropped = 0
            for raw in reply.components(separatedBy: .newlines) {
                let l = bare(raw)
                guard let colon = l.firstIndex(of: ":") else { continue }
                let label = l[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                guard let f = loanFields.first(where: { $0.label.lowercased() == label }) else { continue }
                if let v = acceptLoanValue(String(l[l.index(after: colon)...]), needsNumber: f.needsNumber, known: known, transcript: transcript) {
                    out.append((f.key, v))
                } else { dropped += 1 }
            }
            return (out, dropped)
        }

        /// Splits summaries into consecutive groups of at most `maxWords` words.
        static func groups(_ parts: [String], maxWords: Int) -> [[String]] {
            var out: [[String]] = []
            var cur: [String] = []
            var words = 0
            for p in parts {
                let w = wordCount(p)
                if !cur.isEmpty && words + w > maxWords { out.append(cur); cur = []; words = 0 }
                cur.append(p); words += w
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        }

        /// Same task said twice (in two pieces of a long meeting) is one to-do: the same words, or the same thing
        /// with a verb of the same kind ("Send pay stubs" / "Upload pay stubs and W-2s"). The fuller one is kept.
        static func dedupe(_ todos: [MeetingTodo]) -> [MeetingTodo] {
            var out: [MeetingTodo] = []
            func key(_ t: String) -> Set<String> { Set(words(t).filter { $0.count >= 3 }) }
            func object(_ t: String) -> Set<String> { Set(words(t).dropFirst().filter { $0.count >= 3 && !["the", "and", "for"].contains($0) }) }
            for t in todos {
                let w = key(t.task)
                let i = out.firstIndex { o in
                    guard o.owner == t.owner, !w.isEmpty else { return false }
                    let ow = key(o.task)
                    if !ow.isEmpty, Double(w.intersection(ow).count) / Double(min(w.count, ow.count)) >= 0.75 { return true }
                    guard let v1 = words(o.task).first, let v2 = words(t.task).first, sameVerb(v1, v2) else { return false }
                    let a = object(o.task), b = object(t.task)
                    return !a.isEmpty && !b.isEmpty && (a.isSubset(of: b) || b.isSubset(of: a))
                }
                if let i { if wordCount(t.task) > wordCount(out[i].task) { out[i] = t } } else { out.append(t) }
            }
            return out
        }

        // MARK: wording (house style and regulated words)

        /// Words that turn a fact into a promise in mortgage talk. A note may use one only where the meeting did:
        /// "the loan amount would be $340,000" must not become "they would qualify for $340,000".
        static let claimStems = ["qualif", "approv", "eligib", "guarant", "lock", "promis", "afford", "recommend", "commit", "entitle"]

        /// The regulated words in `s` that the transcript doesn't back up. A word is backed when some transcript
        /// line uses it — and, if `s` has numbers, when one line uses it together with one of those numbers
        /// ("pre-approved" was said, but never next to $340,000, so "pre-approved for $340,000" isn't backed).
        static func unbackedClaims(in s: String, lines: [String]) -> [String] {
            let ws = words(s)
            let nums = Set(numbers(in: s).map(rounded))
            var out: [String] = []
            for stem in claimStems where ws.contains(where: { $0.hasPrefix(stem) }) {
                let saying = lines.filter { words($0).contains { $0.hasPrefix(stem) } }
                let backed = nums.isEmpty ? !saying.isEmpty
                    : saying.contains { !Set(numbers(in: $0).map(rounded)).isDisjoint(with: nums) }
                if !backed { out.append(stem) }
            }
            // A rate or deal called good / low / competitive is a judgment; only the speaker may make it.
            let ns = s as NSString
            for m in judgmentRX.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let phrase = ns.substring(with: m.range).lowercased()
                if !lines.contains(where: { $0.lowercased().contains(phrase) }) { out.append(phrase) }
            }
            return out
        }

        private static let judgmentRX = try! NSRegularExpression(
            pattern: "\\b(?:good|great|best|low|lower|competitive|excellent|attractive|amazing) (?:rate|rates|deal|price|loan)\\b",
            options: .caseInsensitive)

        /// The transcript as one line per turn, for unbackedClaims.
        static func spokenLines(_ lines: [TranscriptLine]) -> [String] { lines.map { oneLine($0.text) } }

        /// Removes sentences that make a claim the meeting didn't (see unbackedClaims).
        static func dropUnbackedSentences(_ text: String, lines: [String]) -> (String, Int) {
            var dropped = 0
            let paragraphs = text.components(separatedBy: "\n").map { para -> String in
                var kept: [String] = []
                para.enumerateSubstrings(in: para.startIndex..., options: .bySentences) { sub, _, _, _ in
                    guard let sub else { return }
                    if unbackedClaims(in: sub, lines: lines).isEmpty { kept.append(sub) } else { dropped += 1 }
                }
                return kept.joined().trimmingCharacters(in: .whitespaces)
            }
            var out = paragraphs.joined(separator: "\n")
            while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
            return (out.trimmingCharacters(in: .whitespacesAndNewlines), dropped)
        }

        private static let firstPersonRX = try! NSRegularExpression(pattern: "\\b(?:I|I'm|I've|I'll|I'd|me|my|myself|we|we're|we've|we'll|our|us)\\b")

        private static let officerRX = try! NSRegularExpression(pattern: "\\b[Tt]he loan officer\\b")

        /// true if the text needs secondPerson: it speaks as the officer ("Maria and I met") or about them
        /// ("The loan officer explained") instead of to them.
        static func needsSecondPerson(_ s: String) -> Bool {
            hasFirstPerson(s) || officerRX.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }

        /// true if the text (outside quotes) speaks as the loan officer: "Maria and I met", "we discussed".
        static func hasFirstPerson(_ s: String) -> Bool {
            let unquoted = s.replacingOccurrences(of: "[\"“][^\"”]*[\"”]", with: "", options: .regularExpression)
            return firstPersonRX.firstMatch(in: unquoted, range: NSRange(unquoted.startIndex..., in: unquoted)) != nil
        }

        /// House style: the loan officer is "you". Rewrites a first-person overview the model wrote anyway
        /// ("Maria and I had a meeting" → "You and Maria had a meeting", "I will send" → "you will send").
        /// "we/our/us" in an overview is the officer and the clients together, so it becomes "you/your/you".
        /// Quoted speech is left alone.
        static func secondPerson(_ s: String) -> String {
            var segments: [String] = []
            var rest = Substring(s)
            while let open = rest.firstIndex(where: { $0 == "\"" || $0 == "“" }),
                  let close = rest[rest.index(after: open)...].firstIndex(where: { $0 == "\"" || $0 == "”" }) {
                segments.append(rewriteFirstPerson(String(rest[..<open])))
                segments.append(String(rest[open...close]))
                rest = rest[rest.index(after: close)...]
            }
            segments.append(rewriteFirstPerson(String(rest)))
            return capitalizeSentences(segments.joined())
        }

        private static func rewriteFirstPerson(_ s: String) -> String {
            var t = s
            let swaps: [(String, String)] = [
                ("\\b([A-Z][a-z]+(?: and [A-Z][a-z]+)?) and I\\b", "you and $1"),
                ("\\bI am\\b", "you are"), ("\\bI was\\b", "you were"), ("\\bI'm\\b", "you're"), ("\\bI've\\b", "you've"),
                ("\\bI'll\\b", "you'll"), ("\\bI'd\\b", "you'd"), ("\\bI\\b", "you"),
                ("\\bmyself\\b", "yourself"), ("\\b[Mm]y\\b", "your"), ("\\bme\\b", "you"),
                ("\\b[Ww]e're\\b", "you're"), ("\\b[Ww]e've\\b", "you've"), ("\\b[Ww]e'll\\b", "you'll"),
                ("\\b[Ww]e are\\b", "you are"), ("\\b[Ww]e were\\b", "you were"), ("\\b[Ww]e\\b", "you"),
                ("\\b[Oo]ur\\b", "your"), ("\\bus\\b", "you"),
                ("\\b[Tt]he loan officer's\\b", "your"), ("\\b[Tt]he loan officer is ", "you are "), ("\\b[Tt]he loan officer was ", "you were "),
                ("\\b[Tt]he loan officer has\\b", "you have"), ("\\b[Tt]he loan officer\\b", "you"),
            ]
            for (p, r) in swaps { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
            return t
        }

        /// Capital letter at the start of the text and after . ! ? (not after a decimal point).
        static func capitalizeSentences(_ s: String) -> String {
            var out = ""
            var cap = true
            var prev: Character = " "
            for ch in s {
                if cap && ch.isLetter { out.append(contentsOf: ch.uppercased()); cap = false }
                else { out.append(ch); if ch.isLetter || ch.isNumber { cap = false } }
                if ch.isWhitespace && ".!?".contains(prev) { cap = true }
                if ch == "\n" { cap = true }
                prev = ch
            }
            return out
        }

        // MARK: repetition

        private static let fillerWords: Set<String> = ["the", "and", "you", "they", "their", "that", "with", "for", "was", "were",
                                                       "about", "also", "would", "this", "from", "have", "has", "had", "are", "them",
                                                       "explained", "told", "said", "discussed", "mentioned", "noted", "noting"]

        private static func contentWords(_ s: String) -> Set<String> {
            Set(words(s).filter { $0.count >= 3 && !fillerWords.contains($0) }.map { String($0.prefix(6)) })
        }

        /// true if two sentences say much the same thing (most of either one's words are in the other). A longer
        /// sentence that adds a fact ("..., who are first-time buyers") isn't a repeat.
        static func sameSentence(_ a: String, _ b: String) -> Bool {
            let wa = contentWords(a), wb = contentWords(b)
            guard !wa.isEmpty, !wb.isEmpty else { return false }
            if min(wa.count, wb.count) < 3 { return wa == wb }   // too short to judge by overlap
            let shared = Double(wa.intersection(wb).count)
            if shared / Double(max(wa.count, wb.count)) >= 0.7 { return true }
            // The same numbers about the same thing, worded differently: "a $410 monthly car payment" and
            // "a car payment of $410 a month".
            let na = Set(numbers(in: a).map(rounded)), nb = Set(numbers(in: b).map(rounded))
            guard !na.isEmpty, !nb.isEmpty, na.isSubset(of: nb) || nb.isSubset(of: na) else { return false }
            return shared / Double(min(wa.count, wb.count)) >= 0.5
        }

        static func sentences(_ s: String) -> [String] {
            var out: [String] = []
            s.enumerateSubstrings(in: s.startIndex..., options: .bySentences) { sub, _, _, _ in
                if let t = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { out.append(t) }
            }
            return out
        }

        /// true if (nearly) everything `a` says is also in `b`: "you need permission to pull credit" is inside
        /// "you need permission to pull their credit, and you'll send the letter within a day or two".
        static func saysLess(_ a: String, than b: String) -> Bool {
            let wa = contentWords(a), wb = contentWords(b)
            guard wa.count >= 4 else { return false }
            return Double(wa.intersection(wb).count) / Double(wa.count) >= 0.8
        }

        /// Drops sentences that repeat an earlier one (in a long meeting the same point comes up in several pieces).
        /// A later sentence that says everything an earlier one did and more replaces it. Keeps paragraphs; a
        /// paragraph left empty goes.
        static func dropRepeatedSentences(_ text: String) -> (String, Int) {
            // (paragraph, sentence) in order; nil = removed.
            var all: [(Int, String?)] = []
            var dropped = 0
            for (p, para) in text.components(separatedBy: "\n").enumerated() {
                for s in sentences(para) {
                    let earlier = all.indices.filter { all[$0].1 != nil }
                    if earlier.contains(where: { sameSentence(all[$0].1!, s) || saysLess(s, than: all[$0].1!) }) { dropped += 1; continue }
                    for i in earlier where saysLess(all[i].1!, than: s) { all[i].1 = nil; dropped += 1 }
                    all.append((p, s))
                }
                all.append((p, ""))   // keeps empty lines (paragraph breaks)
            }
            let count = text.components(separatedBy: "\n").count
            let paras = (0..<count).map { p in all.filter { $0.0 == p }.compactMap { $0.1 }.filter { !$0.isEmpty }.joined(separator: " ") }
            var out = paras.joined(separator: "\n")
            while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
            return (out.trimmingCharacters(in: .whitespacesAndNewlines), dropped)
        }

        // MARK: title

        private static let danglingEnd: Set<String> = ["to", "and", "or", "the", "a", "an", "of", "for", "with", "about", "on", "in",
                                                       "at", "by", "from", "that", "is", "was", "were", "had", "has"]
        private static let sentenceWords: Set<String> = ["had", "has", "have", "was", "were", "is", "are", "met", "discussed", "talked",
                                                         "today", "you", "they", "she", "he", "i", "we", "me", "my", "our"]

        /// A short topic title ("Purchase pre-approval"), not a sentence ("Maria and I had a meeting today to").
        static func isTopicTitle(_ t: String) -> Bool {
            let w = t.split(separator: " ").map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            guard (1...6).contains(w.count), let last = w.last, !danglingEnd.contains(last) else { return false }
            return !w.contains { sentenceWords.contains($0) } && !t.contains(",") && !t.contains(".")
        }

        /// A plain topic title from what the meeting was about, used when the model's title isn't one.
        static func topicTitle(transcript: String) -> String {
            let t = transcript.lowercased()
            if t.contains("refinanc") || t.contains("refi ") { return "Refinance review" }
            if t.contains("heloc") || t.contains("home equity") { return "Home equity options" }
            if t.contains("pre-approv") || t.contains("preapprov") || t.contains("pre approv") { return "Purchase pre-approval" }
            if ["down payment", "purchase price", "new house", "new home", "price range", "make an offer", "making offers"].contains(where: t.contains) {
                return "Home purchase planning"
            }
            if t.contains("rate lock") || t.contains("lock the rate") { return "Rate lock review" }
            return "Client meeting"
        }

        // MARK: to-do wording

        private static let notTaskRX = try! NSRegularExpression(pattern:
            "^(?:sounds good|okay|ok|great|thanks|thank you|got it|yes|sure)\\b|\\b(?:would like to|'d like to|hope to|hoping to|want to|wants to|if possible)\\b|^(?:close|closing)\\b",
            options: .caseInsensitive)
        private static let askVerbs = "send|upload|provide|submit|email|bring|gather|share|sign|forward"
        private static let clientDocs = ["pay stub", "paystub", "w-2", "w2", "bank statement", "tax return", "1099", "photo id", "driver's license", "lease"]

        /// Fixes who owns a to-do and how it reads. The owner is whoever does the task, not whoever said it: the
        /// officer saying "please send me your pay stubs" is a task for Them ("Send last two pay stubs"). Wishes and
        /// goals ("we'd like to close by January") aren't tasks: nil.
        static func fixTodo(owner: Speaker, task: String) -> (Speaker, String)? {
            var t = oneLine(task).trimmingCharacters(in: CharacterSet(charactersIn: " .;-•*\"'"))
            t = t.replacingOccurrences(of: "^(?:please|can you|could you|you need to|they need to|need to)\\s+", with: "",
                                       options: [.regularExpression, .caseInsensitive])
            if notTaskRX.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return nil }
            var who = owner
            let lower = t.lowercased()
            let askedOfThem = lower.range(of: "^(?:\(askVerbs))\\b.*\\b(?:me|your)\\b", options: .regularExpression) != nil
            let theirDocs = lower.range(of: "^(?:\(askVerbs))\\b", options: .regularExpression) != nil
                && clientDocs.contains(where: lower.contains) && !lower.contains(" to ")
            if owner == .you && (askedOfThem || theirDocs) {
                who = .them
                t = t.replacingOccurrences(of: "^((?:\(askVerbs)))\\s+me\\b\\s*", with: "$1 ", options: [.regularExpression, .caseInsensitive])
                t = t.replacingOccurrences(of: "\\byour\\s+", with: "", options: [.regularExpression, .caseInsensitive])
                t = t.replacingOccurrences(of: "\\s+to me\\b", with: "", options: [.regularExpression, .caseInsensitive])
            } else if owner == .them, lower.range(of: "^(?:\(askVerbs))\\s+me\\b", options: .regularExpression) != nil {
                who = .you   // a client asking the officer: "send me the checklist"
                t = t.replacingOccurrences(of: "^((?:\(askVerbs)))\\s+me\\b\\s*", with: "$1 them ", options: [.regularExpression, .caseInsensitive])
            }
            if who == .them { t = t.replacingOccurrences(of: "\\byour\\s+", with: "their ", options: .regularExpression) }
            if who == .you { t = t.replacingOccurrences(of: "\\bmyself\\b", with: "yourself", options: .regularExpression) }
            t = t.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            guard t.count >= 3 else { return nil }
            return (who, t.prefix(1).uppercased() + t.dropFirst())
        }

        // MARK: to-dos against what was said

        private static let promiseRX = try! NSRegularExpression(pattern: "\\b(?:i will|i'll|i'm going to|i can|let me|we will|we'll|we're going to|we can)\\b", options: .caseInsensitive)
        private static let requestRX = try! NSRegularExpression(pattern: "\\b(?:please|can you|could you|you need to|i need you to|you'll need to|make sure to)\\b", options: .caseInsensitive)
        private static let verbFamilies: [Set<String>] = [["send", "email", "forw", "shar", "mail"], ["uplo", "send", "subm", "prov"],
                                                           ["sche", "set"], ["revi", "go"], ["call", "reac"]]

        private static func sameVerb(_ a: String, _ b: String) -> Bool {
            let x = String(a.lowercased().prefix(4)), y = String(b.lowercased().prefix(4))
            return x == y || verbFamilies.contains { $0.contains(x) && $0.contains(y) }
        }

        private static let negationRX = try! NSRegularExpression(pattern: "\\b(?:don't|do not|not|never|shouldn't|should not|won't|avoid|let's not)\\b", options: .caseInsensitive)
        private static let taskTalkRX = try! NSRegularExpression(pattern: "\\b(?:need|needs|will|please|can you|could you|let's|let me|going to)\\b|'ll\\b", options: .caseInsensitive)

        /// Where a to-do came from in the transcript, and who will do it. `matched` = the task was said: a clause
        /// with the task's verb and most of its words, or two neighbouring lines with most of its words and some
        /// task talk ("I need", "we'll", "please"). The model makes up tasks from plain facts ("send car payment"
        /// from "one car payment, $410 a month"); those match nothing. `owner`, when the clause is a clear promise
        /// or request: a "You:" line saying "I'll send you the checklist" is the officer's task; "please send me
        /// your pay stubs" is the clients'.
        static func source(of task: String, in transcript: String) -> (matched: Bool, owner: Speaker?) {
            guard let verb = words(task).first else { return (false, nil) }
            let want = contentWords(task).subtracting([String(verb.prefix(6))])
            var matched = false
            let raws = transcript.components(separatedBy: "\n")
            // Something the officer said not to do isn't a task: "don't open any new credit cards" must never
            // become "Them: Open new credit cards".
            if !want.isEmpty {
                for raw in raws {
                    for clause in raw.components(separatedBy: CharacterSet(charactersIn: ",.;?!")) {
                        let hits = want.intersection(contentWords(clause)).count
                        if Double(hits) / Double(want.count) >= 0.6, hits >= min(2, want.count),
                           negationRX.firstMatch(in: clause, range: NSRange(clause.startIndex..., in: clause)) != nil { return (false, nil) }
                    }
                }
            }
            for (i, raw) in raws.enumerated() {
                let speaker: Speaker
                let line: String
                if raw.hasPrefix("You: ") { speaker = .you; line = String(raw.dropFirst(5)) }
                else if raw.hasPrefix("Them: ") { speaker = .them; line = String(raw.dropFirst(6)) }
                else { continue }
                if !matched, !want.isEmpty {
                    let window = raws[i..<min(raws.count, i + 2)].joined(separator: " ")
                    let hits = want.intersection(contentWords(window)).count
                    if Double(hits) / Double(want.count) >= 0.6, hits >= min(2, want.count),
                       taskTalkRX.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)) != nil { matched = true }
                }
                for clause in line.components(separatedBy: CharacterSet(charactersIn: ",.;?!")) {
                    let cw = words(clause)
                    guard cw.contains(where: { sameVerb($0, verb) }) else { continue }
                    let overlap = want.isEmpty ? 1 : Double(want.intersection(contentWords(clause)).count) / Double(want.count)
                    guard overlap >= 0.5 else { continue }
                    matched = true
                    // The promise or request nearest before the verb decides: "I'll run credit and send you the
                    // letter" is the speaker's promise to send.
                    let ns = clause as NSString
                    let verbAt = clause.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'") })
                        .first(where: { sameVerb(String($0), verb) }).map { ns.range(of: String($0), options: .caseInsensitive).location } ?? NSNotFound
                    guard verbAt != NSNotFound else { continue }
                    let before = NSRange(location: 0, length: verbAt)
                    let p = promiseRX.matches(in: clause, range: before).last?.range.location ?? -1
                    let q = requestRX.matches(in: clause, range: before).last?.range.location ?? -1
                    if p > q { return (true, speaker) }
                    if q > p { return (true, speaker == .you ? .them : .you) }
                }
            }
            return (matched, nil)
        }

        static func cleanTitle(_ s: String, fallback: String) -> String {
            var t = oneLine(s).trimmingCharacters(in: CharacterSet(charactersIn: " .:\"'*#“”"))
            t = t.replacingOccurrences(of: "^title\\s*[:\\-–]\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            t = meetingNotCall(t)
            // A title is a noun phrase, so a last word "call" is the noun: "Pre-approval call".
            t = t.replacingOccurrences(of: "\\bcall$", with: "meeting", options: [.regularExpression, .caseInsensitive])
            // A sentence or a cut-off phrase isn't a title; cutting it shorter would only hide that.
            return isTopicTitle(t) ? t : fallback
        }

        /// Keeps the overview in plain paragraphs: no headings, no "Here is the overview:" lead-in, "the call" → "the meeting".
        static func cleanOverview(_ s: String) -> String {
            var lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            lines = lines.map { l in l.hasPrefix("#") ? String(l.drop(while: { $0 == "#" || $0 == " " })) : l }
            if let i = lines.firstIndex(where: { !$0.isEmpty }) {
                let f = lines[i]
                let lead = try! NSRegularExpression(pattern: "^(?:here is|here's|here are|overview)\\b[^:\\n]*:\\s*", options: .caseInsensitive)
                if let m = lead.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)) {
                    let rest = String(f[Range(m.range, in: f)!.upperBound...])
                    if rest.isEmpty { lines.remove(at: i) } else { lines[i] = rest }
                } else if f.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " :*")) == "overview" {
                    lines.remove(at: i)
                }
            }
            return meetingNotCall(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // MARK: picking the relevant parts for a question

        private static let stopwords: Set<String> = [
            "the", "a", "an", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "did", "do", "does",
            "what", "whats", "which", "who", "whom", "when", "where", "why", "how", "is", "are", "was", "were", "be",
            "they", "them", "their", "you", "your", "we", "our", "i", "me", "my", "it", "its", "that", "this", "there",
            "say", "said", "mention", "mentioned", "tell", "told", "talk", "talked", "any", "anything", "much", "many",
            "meeting", "call", "can", "could", "would", "should", "will", "have", "has", "had", "get", "got",
        ]
        private static let numberish: Set<String> = ["price", "much", "rate", "amount", "cost", "income", "salary", "payment", "down",
                                                     "percent", "budget", "many", "number", "date", "when", "afford", "loan"]

        static func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
                .map { $0.replacingOccurrences(of: "'", with: "") }.filter { !$0.isEmpty }
        }

        /// The parts of the transcript most likely to hold the answer, in meeting order, at most `maxWords` words.
        /// A transcript that fits is returned whole.
        static func relevantLines(for question: String, in lines: [TranscriptLine], maxWords: Int) -> [TranscriptLine] {
            let total = lines.reduce(0) { $0 + wordCount($1.text) + 1 }
            if total <= maxWords { return lines }
            let windows = pieces(lines, maxWords: 180)
            let qAll = words(question)
            let q = Set(qAll.filter { !stopwords.contains($0) }).map { String($0.prefix(5)) }
            let wantsNumber = qAll.contains { numberish.contains($0) }
            let windowWords = windows.map { w in w.flatMap { words($0.text) }.map { String($0.prefix(5)) } }
            let df = Dictionary(q.map { term in (term, windowWords.filter { $0.contains(term) }.count) }, uniquingKeysWith: { a, _ in a })
            let n = Double(windows.count)
            let scores: [Double] = windowWords.enumerated().map { i, ws in
                var s = 0.0
                for term in q { let c = ws.filter { $0 == term }.count; if c > 0 { s += (1 + log(Double(c))) * log(1 + n / Double(max(1, df[term] ?? 1))) } }
                if wantsNumber && windows[i].contains(where: { !numbers(in: $0.text).isEmpty }) { s += 0.3 }
                return s
            }
            var chosen: [Int] = []
            var used = 0
            for i in scores.indices.sorted(by: { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }) {
                let w = windows[i].reduce(0) { $0 + wordCount($1.text) + 1 }
                if used + w > maxWords { continue }
                chosen.append(i); used += w
            }
            return chosen.sorted().flatMap { windows[$0] }
        }

        static func isNotFound(_ answer: String) -> Bool {
            let a = answer.lowercased()
            return a.contains("not in transcript") || a.contains("not in the transcript") || a.contains("wasn't mentioned")
                || a.contains("was not mentioned") || a.contains("not mentioned") || a.contains("doesn't say") || a.contains("does not say")
                || a.contains("no information") || a.contains("doesn't mention") || a.contains("does not mention")
                || a.contains("not discussed") || a.contains("wasn't discussed") || a.contains("isn't mentioned")
                || a.contains("not specified") || a.contains("didn't mention") || a.contains("did not mention")
                || a.contains("cannot find") || a.contains("can't find") || a.contains("couldn't find")
        }
    }
}

// MARK: - Engine (FoundationModels)

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private final class Engine {

    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private typealias C = MeetingSummarizer.Checks

    // Plain-text replies only. Measured 2026-10-17: guided generation (a schema) was refused on every mortgage
    // meeting we tried, while the same request as plain text worked every time; the small model also refuses when
    // told "never give advice". So each reply is plain text in a simple line format that the Checks parse and
    // verify.
    static let rules = """
    You help a loan officer keep accurate records of their own client meetings. In the transcript, "You:" lines \
    are the loan officer and "Them:" lines are the clients.
    Rules:
    - Use only what was said in the transcript. Never invent names, numbers, dates, amounts or rates.
    - Copy every number exactly as it appears in the transcript.
    - Write plain, friendly English from the loan officer's side: the loan officer is "you" and the clients are \
    "they", or their names if their names were said. Never write "I", "me", "we" or "our".
    - For qualifying, approval, rates, rate locks and loan amounts, keep the speaker's own words. If someone said \
    "the loan amount would be" an amount, write that; never turn it into "they qualify for" or "they are approved for".
    - Always say "meeting", never "call".
    """

    private func ask(_ task: String, _ prompt: String, maxTokens: Int) async throws -> String {
        let s = LanguageModelSession(model: model, instructions: Self.rules + "\n" + task)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
        return try await withTimeout(MeetingSummarizer.callTimeout) {
            try await s.respond(to: prompt, options: options).content
        }
    }

    private static func wrap(_ text: String) -> String { "<transcript>\n\(text)\n</transcript>" }

    // MARK: summarize

    func summarize(_ lines: [TranscriptLine], into base: MeetingNote, loanDetails: Bool) async -> (MeetingNote, String, MeetingSummarizer.Gaps) {
        var note = base
        var diag: [String] = []
        var gaps: MeetingSummarizer.Gaps = []
        let fullText = C.render(lines)
        let known = C.knownNumbers(in: fullText)
        let pieces = C.pieces(lines, maxWords: MeetingSummarizer.wordsPerPiece)
        diag.append("\(pieces.count) piece\(pieces.count == 1 ? "" : "s")")

        // Overview. Short meeting: straight from the transcript (keeps the detail). Long: each piece summarised,
        // then the summaries combined (in rounds, if even they are too long for one call).
        // Length follows the meeting: a 2-minute chat gets a few sentences (asking for 300 words invites filler and
        // made-up detail), a long meeting at most ~450 words (a 2–3 minute read).
        let spokenWords = C.wordCount(fullText)
        let most = min(450, max(60, spokenWords * 6 / 10)), least = max(30, most / 2)
        let shape = most < 150 ? "one short paragraph" : "3 to 5 short paragraphs separated by blank lines"
        let overviewTask = """
        Write an overview of this meeting for the loan officer: \(shape), about \(least) to \(most) words. Start with \
        what the meeting was about, then the key facts and numbers, what was decided, open questions, and what happens \
        next. Write "you" for the loan officer, for example "You met with Maria to talk about" or "You explained". \
        Reply with the overview only.
        """
        var overview = ""
        if pieces.count == 1 {
            do { overview = try await ask(overviewTask, Self.wrap(fullText), maxTokens: 1000) }
            catch { diag.append("overview failed: \(Self.describe(error))"); gaps.insert(.overview) }
        } else {
            var summaries: [String] = []
            for (i, piece) in pieces.enumerated() {
                do {
                    let s = try await ask("This is part \(i + 1) of \(pieces.count) of a meeting transcript. Summarize what was discussed in this part in 4 to 8 sentences, with the key facts and numbers. Write \"you\" for the loan officer. Reply with the summary only.",
                                          Self.wrap(C.render(piece)), maxTokens: 450)
                    let sum = C.oneLine(C.cleanOverview(s))
                    summaries.append(C.needsSecondPerson(sum) ? C.secondPerson(sum) : sum)
                } catch { diag.append("piece \(i + 1) failed: \(Self.describe(error))"); gaps.insert(.overview) }
            }
            // The same point often comes up in several pieces; say it once before combining, or the combined overview
            // repeats it once per piece (measured: five paragraphs that each began "You discussed the pre-approval...").
            var parts: [String] = []
            var seen: [String] = []
            for sum in summaries {
                let fresh = C.sentences(sum).filter { s in !seen.contains { C.sameSentence($0, s) } }
                seen += fresh
                if !fresh.isEmpty { parts.append(fresh.joined(separator: " ")) }
            }
            while parts.count > 1 && C.wordCount(parts.joined(separator: "\n")) > MeetingSummarizer.wordsPerPiece {
                let groups = C.groups(parts, maxWords: MeetingSummarizer.wordsPerPiece)
                if groups.count >= parts.count { break }   // no progress; send what we have
                var merged: [String] = []
                for g in groups { merged.append(g.count == 1 ? g[0] : await shorten(g)) }
                parts = merged
            }
            if !parts.isEmpty {
                let notes = parts.joined(separator: "\n\n")
                let combineTask = """
                    These are notes from one long meeting, in order. Merge them into one overview for the loan officer: \
                    3 to 5 short paragraphs separated by blank lines, about 250 to 450 words. Group the paragraphs by \
                    topic (the clients and their plans, the numbers, documents and next steps), not by part of the meeting. \
                    Say each fact once. Start each paragraph differently, and never mention parts or notes. Write "you" for \
                    the loan officer. Reply with the overview only.
                    """
                do {
                    overview = try await ask(combineTask, "<notes>\n\(notes)\n</notes>", maxTokens: 1000)
                } catch {
                    diag.append("overview failed: \(Self.describe(error))"); gaps.insert(.overview)
                    overview = summaries.joined(separator: "\n\n")
                }
            }
        }
        // Clean-up, in order: lead-ins and headings, a cut-off last sentence, house style ("you", never "I"), repeats,
        // then the safety rails (invented numbers, claims the meeting didn't make).
        var text = C.dropUnfinishedEnding(C.cleanOverview(overview))
        if C.needsSecondPerson(text) { text = C.secondPerson(text); diag.append("overview rewritten as \"you\"") }
        let (unrepeated, repeats) = C.dropRepeatedSentences(text)
        if repeats > 0 { diag.append("\(repeats) repeated sentence(s) dropped") }
        let (backed, claims) = C.dropUnbackedSentences(unrepeated, lines: C.spokenLines(lines))
        if claims > 0 { diag.append("\(claims) overview sentence(s) with an unsaid claim dropped") }
        let (safe, droppedSentences) = C.dropSentencesWithUnknownNumbers(backed, known: known)
        if droppedSentences > 0 { diag.append("\(droppedSentences) overview sentence(s) dropped") }
        note.overview = safe.isEmpty ? "Verbaline couldn't write an overview for this meeting. The full transcript is below." : safe
        if gaps.contains(.overview) && !safe.isEmpty { note.overview += "\n\n" + MeetingSummarizer.Gaps.incompleteOverview }

        // Title, from the overview (short, cheap, and never sees a raw number it could garble).
        if !safe.isEmpty {
            do {
                let t = try await ask("Name the topic of these meeting notes in 2 to 5 words, like a folder label: for example \"Purchase pre-approval\", \"Refinance options\" or \"Rate lock questions\". Not a sentence, no names, no quotes. Reply with the topic only.",
                                      "<notes>\n\(safe)\n</notes>", maxTokens: 24)
                note.title = C.cleanTitle(t, fallback: "")
                if !C.unknownNumbers(in: note.title, known: known).isEmpty || !C.unbackedClaims(in: note.title, lines: C.spokenLines(lines)).isEmpty { note.title = "" }
            } catch { diag.append("title failed: \(Self.describe(error))") }
        }
        if note.title.isEmpty { note.title = C.topicTitle(transcript: fullText); diag.append("title from topic words") }

        // To-dos, per piece.
        var todos: [MeetingTodo] = []
        var droppedTodos = 0
        for (i, piece) in pieces.enumerated() {
            do {
                let out = try await ask("""
                    List the next steps from this meeting: only tasks that someone promised or was asked to do. Write \
                    one per line as "Loan officer: <task>" when the loan officer will do it, or "Clients: <task>" when \
                    the clients will do it. Label each task by who will do it, not by who said it: when the loan officer \
                    says "send me your <document>", write "Clients: Send <document>". Write each task as a short \
                    action starting with a verb, at most 15 words, saying exactly what (which documents) and any \
                    deadline that was said. Give each task \
                    its own line. Leave out questions, wishes and goals (such as hoping to close by a date), ideas that \
                    were not agreed, and anything the loan officer said not to do. If there are none, reply None.
                    """, Self.wrap(C.render(piece)), maxTokens: 300)
                let (got, dropped) = C.parseTodos(out, known: known, transcript: C.render(piece))
                todos += got; droppedTodos += dropped
            } catch { diag.append("to-dos piece \(i + 1) failed: \(Self.describe(error))"); gaps.insert(.todos) }
        }
        note.todos = C.dedupe(todos)
        if droppedTodos > 0 { diag.append("\(droppedTodos) to-do(s) dropped") }

        // Loan details, per piece; later in the meeting wins (people correct themselves).
        if loanDetails {
            var found: [String: String] = [:]
            var dropped = 0
            let labels = C.loanFields.map { $0.label }.joined(separator: ", ")
            for (i, piece) in pieces.enumerated() {
                let text = C.render(piece)
                do {
                    let out = try await ask("""
                        List the loan details that were actually said in this transcript, one per line, as "Label: value", \
                        using only these labels: \(labels). Purpose means what the loan is for, such as buying a first home or a \
                        refinance. Copy amounts, rates and dates exactly as said. Leave out any \
                        label that wasn't said. If none were said, reply None.
                        """, Self.wrap(text), maxTokens: 300)
                    let (got, d) = C.parseLoanDetails(out, known: C.knownNumbers(in: text), transcript: text)
                    dropped += d
                    for (key, v) in got {
                        if key == "documents", let old = found[key], !old.lowercased().contains(v.lowercased()) {
                            found[key] = old + ", " + v.prefix(1).lowercased() + v.dropFirst()
                        } else { found[key] = v }
                    }
                } catch { diag.append("loan details piece \(i + 1) failed: \(Self.describe(error))"); gaps.insert(.loanDetails) }
            }
            note.loanDetails = C.loanFields.compactMap { f in found[f.key].map { MeetingNote.LoanDetail(label: f.label, value: $0) } }
            if dropped > 0 { diag.append("\(dropped) loan detail(s) dropped") }
        }
        return (note, diag.joined(separator: ", "), gaps)
    }

    /// Several part summaries → one shorter one (only for very long meetings).
    private func shorten(_ parts: [String]) async -> String {
        let joined = parts.joined(separator: "\n\n")
        do {
            let out = try await ask("Combine these summaries of consecutive parts of a meeting into one summary of 6 to 10 sentences. Keep the key facts and numbers. Reply with the summary only.",
                                    "<notes>\n\(joined)\n</notes>", maxTokens: 500)
            return C.oneLine(C.cleanOverview(out))
        } catch {
            let each = MeetingSummarizer.wordsPerPiece / max(1, parts.count) / 2
            return parts.map { $0.split(separator: " ").prefix(each).joined(separator: " ") }.joined(separator: " ")
        }
    }

    // MARK: answer

    func answer(_ question: String, from lines: [TranscriptLine]) async -> (String, String) {
        let picked = C.relevantLines(for: question, in: lines, maxWords: MeetingSummarizer.wordsPerPiece)
        let text = C.render(picked)
        let known = C.knownNumbers(in: text)
        let safeQ = C.oneLine(question).replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        let task = """
        Answer the loan officer's question using only the transcript. Reply in 1 to 3 short sentences.
        If the transcript does not contain the answer, reply exactly: NOT IN TRANSCRIPT
        Never guess and never use outside knowledge.
        """
        do {
            let out = try await ask(task, "\(Self.wrap(text))\n\nQuestion: \(safeQ)", maxTokens: 220)
            let a = C.cleanOverview(out)
            if a.isEmpty || C.isNotFound(a) { return (MeetingSummarizer.notFound, "not found (\(picked.count) of \(lines.count) lines read)") }
            if !C.unknownNumbers(in: a, known: known).isEmpty { return (MeetingSummarizer.notFound, "answer had a number not in the transcript: \(a)") }
            if !C.unbackedClaims(in: a, lines: C.spokenLines(picked)).isEmpty { return (MeetingSummarizer.notFound, "answer made a claim the meeting didn't: \(a)") }
            return (a, "answered from \(picked.count) of \(lines.count) lines")
        } catch {
            return ("Verbaline couldn't answer that right now (\(Self.describe(error))). Try again in a moment.", "failed: \(Self.describe(error))")
        }
    }

    // MARK: plumbing

    static func describe(_ error: Error) -> String {
        if error is TimedOut { return "timed out" }
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: return "too long"
            case .guardrailViolation:        return "guardrailViolation"
            case .refusal:                   return "refusal"
            case .assetsUnavailable:         return "model not ready"
            case .rateLimited, .concurrentRequests: return "busy"
            default:                         return "generation error"
            }
        }
        return String(describing: error)
    }

    struct TimedOut: Error {}

    private func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await work() }
            g.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw TimedOut() }
            defer { g.cancelAll() }
            return try await g.next()!
        }
    }
}
#endif

// MARK: - MeetingStore (Markdown files)

/// Notes as Markdown files, one per meeting, in ~/Documents/Verbaline Notes/ (or `folder`, for tests).
/// The file reads well on its own; a hidden comment at the top keeps the exact date and length for load().
struct MeetingStore {

    let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verbaline Notes", isDirectory: true)
    }

    /// Writes the note and returns its file. Never overwrites another note: a second note with the same name
    /// gets " 2", " 3", ... Throws if the folder or file can't be written, so the caller can tell the user.
    /// `gaps` (MeetingSummarizer.lastGaps) marks sections that may be incomplete because a model call failed.
    func save(_ note: MeetingNote, gaps: MeetingSummarizer.Gaps = []) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = "\(Self.fileStamp.string(from: note.date)) \(Self.safeFileName(note.title))"
        var url = folder.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).md"); n += 1
        }
        try Self.markdown(note, gaps: gaps).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Every note, newest first.
    func list() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "md" }.sorted { a, b in
            let da = Self.dateFromFileName(a) ?? Self.modified(a), db = Self.dateFromFileName(b) ?? Self.modified(b)
            return da != db ? da > db : a.lastPathComponent > b.lastPathComponent
        }
    }

    func load(_ url: URL) -> MeetingNote? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self.parse(text)
    }

    // MARK: Markdown out

    static func markdown(_ note: MeetingNote, gaps: MeetingSummarizer.Gaps = []) -> String {
        var md: [String] = []
        md.append("<!-- verbaline-note v1 date=\(iso.string(from: note.date)) duration=\(String(format: "%.1f", note.duration)) -->")
        md.append("# \(MeetingSummarizer.Checks.oneLine(note.title))")
        md.append("")
        md.append("- Date: \(shownDate.string(from: note.date))")
        md.append("- Length: \(lengthText(note.duration))")
        md.append("- App: \(MeetingSummarizer.Checks.oneLine(note.appName))")
        md.append("")
        md.append("## Overview")
        md.append("")
        md.append(note.overview.components(separatedBy: "\n").map { l in l.hasPrefix("#") ? "\\" + l : l }.joined(separator: "\n"))
        md.append("")
        md.append("## To do")
        md.append("")
        if gaps.contains(.todos) { md.append("_\(MeetingSummarizer.Gaps.incompleteNote)_") }
        else if note.todos.isEmpty { md.append("_No to-dos._") }
        for t in note.todos { md.append("- [ ] \(MeetingSummarizer.Checks.speakerName(t.owner)): \(MeetingSummarizer.Checks.oneLine(t.task))") }
        md.append("")
        md.append("## Loan details")
        md.append("")
        if gaps.contains(.loanDetails) { md.append("_\(MeetingSummarizer.Gaps.incompleteNote)_") }
        else if note.loanDetails.isEmpty { md.append("_None._") }
        for d in note.loanDetails { md.append("- \(MeetingSummarizer.Checks.oneLine(d.label)): \(MeetingSummarizer.Checks.oneLine(d.value))") }
        md.append("")
        md.append("## Transcript")
        md.append("")
        for l in note.transcript {
            md.append("[\(timestamp(l.start))] \(MeetingSummarizer.Checks.speakerName(l.speaker)): \(MeetingSummarizer.Checks.oneLine(l.text))")
        }
        md.append("")
        return md.joined(separator: "\n")
    }

    // MARK: Markdown in

    static func parse(_ text: String) -> MeetingNote? {
        let lines = text.components(separatedBy: "\n")
        guard let titleLine = lines.first(where: { $0.hasPrefix("# ") }) else { return nil }
        var note = MeetingNote(title: String(titleLine.dropFirst(2)).trimmingCharacters(in: .whitespaces), date: Date(timeIntervalSince1970: 0),
                               duration: 0, appName: "", overview: "", todos: [], loanDetails: [], transcript: [])
        var section = ""
        var overview: [String] = []
        var gotHidden = false
        for line in lines {
            if line.hasPrefix("<!-- verbaline-note") {
                for part in line.split(separator: " ") {
                    if part.hasPrefix("date="), let d = iso.date(from: String(part.dropFirst(5))) { note.date = d; gotHidden = true }
                    if part.hasPrefix("duration="), let v = Double(part.dropFirst(9)) { note.duration = v }
                }
                continue
            }
            if line.hasPrefix("## ") { section = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased(); continue }
            if line.hasPrefix("# ") { continue }
            switch section {
            case "":
                if line.hasPrefix("- Date: "), !gotHidden, let d = shownDate.date(from: String(line.dropFirst(8))) { note.date = d }
                if line.hasPrefix("- Length: "), !gotHidden { note.duration = parseLength(String(line.dropFirst(10))) }
                if line.hasPrefix("- App: ") { note.appName = String(line.dropFirst(7)) }
            case "overview":
                overview.append(line.hasPrefix("\\#") ? String(line.dropFirst()) : line)
            case "to do":
                guard line.hasPrefix("- [") else { continue }
                let body = line.drop(while: { $0 != "]" }).dropFirst().trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("You: ") { note.todos.append(MeetingTodo(owner: .you, task: String(body.dropFirst(5)))) }
                else if body.hasPrefix("Them: ") { note.todos.append(MeetingTodo(owner: .them, task: String(body.dropFirst(6)))) }
            case "loan details":
                guard line.hasPrefix("- "), let colon = line.range(of: ": ") else { continue }
                note.loanDetails.append(.init(label: String(line[line.index(line.startIndex, offsetBy: 2)..<colon.lowerBound]),
                                              value: String(line[colon.upperBound...])))
            case "transcript":
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
                let stamp = String(line[line.index(after: line.startIndex)..<close])
                let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                let speaker: Speaker
                let said: String
                if rest.hasPrefix("You: ") || rest == "You:" { speaker = .you; said = String(rest.dropFirst(4)) }
                else if rest.hasPrefix("Them: ") || rest == "Them:" { speaker = .them; said = String(rest.dropFirst(5)) }
                else { continue }
                note.transcript.append(TranscriptLine(speaker: speaker, start: parseTimestamp(stamp), text: said.trimmingCharacters(in: .whitespaces)))
            default: continue
            }
        }
        note.overview = overview.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return note
    }

    // MARK: formats

    /// "[mm:ss]"; minutes keep counting past 59 ("75:12") so a long meeting still sorts and reads simply.
    static func timestamp(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func parseTimestamp(_ s: String) -> TimeInterval {
        let p = s.split(separator: ":").compactMap { Double($0) }
        return p.reduce(0) { $0 * 60 + $1 }
    }

    static func lengthText(_ d: TimeInterval) -> String {
        let s = Int(d.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func parseLength(_ s: String) -> TimeInterval {
        var total = 0.0
        let parts = s.split(separator: " ")
        var i = 0
        while i + 1 < parts.count {
            if let v = Double(parts[i]) {
                switch parts[i + 1] { case "h": total += v * 3600; case "min": total += v * 60; default: total += v }
            }
            i += 2
        }
        return total
    }

    static func safeFileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t").union(.controlCharacters)
        var t = String(String.UnicodeScalarView(title.unicodeScalars.map { bad.contains($0) ? " " : $0 }))
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if t.count > 60 { t = String(t.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return t.isEmpty ? "Meeting" : t
    }

    private static func dateFromFileName(_ url: URL) -> Date? {
        let name = url.lastPathComponent
        guard name.count >= 15 else { return nil }
        return fileStamp.date(from: String(name.prefix(15)))
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HHmm"; return f
    }()
    private static let shownDate: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}
