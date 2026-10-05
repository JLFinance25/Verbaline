import Foundation
import AVFoundation
import Speech

// CLI harness for PersonalDictionary and AppleTranscriber.vocabulary.
//
//   dictionary_test [--skip-stt]
//
// Run it from the project root (paths are relative to the current directory):
//   swiftc -swift-version 5 -O -parse-as-library src/AppleTranscriber.swift src/PersonalDictionary.swift \
//       tests/dictionary_test.swift -o build/dictionary_test/dictionary_test
//   build/dictionary_test/dictionary_test
//
// What it does, in order:
//   1. apply(to:) unit tests on tricky ordinary sentences (pass/fail).
//   2. File behaviour tests: seeding, never overwriting, parsing, reload on change, threads, speed.
//   3. AppleTranscriber.vocabulary API tests (cleanup rules, thread safety).
//   4. Speech comparison: makes clips with `say`, transcribes each with vocabulary empty vs the
//      dictionary terms, then runs apply(to:); prints every version, a score, and latencies.
//      Also checks the timeout path still recovers with a vocabulary set.
//
// Environment:
//   DICT_ENGINE=speech|dictation|both   which recognizers to compare (default: both)
//   DICT_RUNS=N                         timed transcribe() calls per clip and mode (default 5)
//   DICT_OUT=dir                        where clips and the seeded dictionary copy go (default build/dictionary_test)
//
// Exit code: 0 = every check passed, 1 = at least one failed.

// MARK: - tiny test framework

final class Tally: @unchecked Sendable {
    static let shared = Tally()
    private let lock = NSLock()
    private(set) var passed = 0
    private(set) var failed = 0
    func record(_ ok: Bool) { lock.withLock { if ok { passed += 1 } else { failed += 1 } } }
}

func visible(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
}

func check(_ name: String, _ got: String, _ want: String) {
    let ok = got == want
    Tally.shared.record(ok)
    if ok { print("  PASS  \(name)") }
    else { print("  FAIL  \(name)\n          input/got : \(visible(got))\n          wanted    : \(visible(want))") }
}

func checkTrue(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    Tally.shared.record(ok)
    if ok { print("  PASS  \(name)") }
    else { print("  FAIL  \(name)  \(detail())") }
}

/// Apply `dict` to `input` and compare with `want`. Also checks apply() is idempotent.
func expectApply(_ dict: PersonalDictionary, _ input: String, _ want: String, _ label: String? = nil) {
    let got = dict.apply(to: input)
    let name = label ?? "\"\(visible(input))\""
    if got == want {
        Tally.shared.record(true)
        print("  PASS  \(name)  ->  \"\(visible(got))\"")
    } else {
        Tally.shared.record(false)
        print("  FAIL  \(name)\n          input  : \(visible(input))\n          got    : \(visible(got))\n          wanted : \(visible(want))")
    }
    let again = dict.apply(to: got)
    if again != got {
        Tally.shared.record(false)
        print("  FAIL  idempotent: apply(apply(x)) != apply(x) for \"\(visible(input))\"\n          once : \(visible(got))\n          twice: \(visible(again))")
    } else {
        Tally.shared.record(true)
    }
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

// MARK: - 1. apply() unit tests

func runApplyTests(seed: PersonalDictionary, custom: PersonalDictionary) {
    print("\n=== 1. apply(to:) unit tests (seeded dictionary)")

    print("-- ordinary casing fixes")
    expectApply(seed, "your dti is 43.5% and your ltv is 80", "your DTI is 43.5% and your LTV is 80")
    expectApply(seed, "We can do a heloc or a cash out refinance through fannie mae.",
                "We can do a HELOC or a cash-out refinance through Fannie Mae.")
    expectApply(seed, "send the loan estimate and the closing disclosure", "send the Loan Estimate and the Closing Disclosure")
    expectApply(seed, "Freddie Mac and Fannie Mae are fine as written.", "Freddie Mac and Fannie Mae are fine as written.")
    expectApply(seed, "talk to freddy mac about it", "talk to Freddie Mac about it")
    expectApply(seed, "The mortgage insurance is PMI.", "The mortgage insurance is PMI.")
    expectApply(seed, "Mortgage Insurance is required.", "Mortgage insurance is required.")
    expectApply(seed, "That is a Non-QM loan, or non qm, or nonqm.", "That is a non-QM loan, or non-QM, or non-QM.")
    expectApply(seed, "A Cash Out Refi is possible.", "A cash-out refi is possible.")

    print("-- escrow casing: sentence start vs mid-sentence")
    expectApply(seed, "Escrow closes Friday.", "Escrow closes Friday.")
    expectApply(seed, "we put it in Escrow today.", "we put it in escrow today.")
    expectApply(seed, "escrow is required.", "escrow is required.")
    expectApply(seed, "Is that in escrow? Escrow takes 30 days.", "Is that in escrow? Escrow takes 30 days.")
    expectApply(seed, "He said Escrow is next.", "He said escrow is next.")
    expectApply(seed, "He said \"Escrow is next.\"", "He said \"Escrow is next.\"")
    expectApply(seed, "First line.\nescrow second\nEscrow third", "First line.\nescrow second\nEscrow third")
    expectApply(seed, "The ESCROW officer", "The ESCROW officer", "all-caps word is left alone for a lowercase entry")

    print("-- must NOT mangle normal English")
    expectApply(seed, "I hurt my arm", "I hurt my arm")
    expectApply(seed, "My arm hurts, and the arm of the chair is broken.", "My arm hurts, and the arm of the chair is broken.")
    expectApply(seed, "He broke his arm and took out a loan.", "He broke his arm and took out a loan.")
    expectApply(seed, "They walked arm in arm.", "They walked arm in arm.")
    expectApply(seed, "the VA hospital", "the VA hospital")
    expectApply(seed, "the va hospital", "the VA hospital")
    expectApply(seed, "I'll be there at 3", "I'll be there at 3")
    expectApply(seed, "farm warm alarm harm charm Parliament armchair", "farm warm alarm harm charm Parliament armchair")
    expectApply(seed, "Vacation in Nevada, Java and lava; valid vase, Vatican", "Vacation in Nevada, Java and lava; valid vase, Vatican")
    expectApply(seed, "apron aprons napkin", "apron aprons napkin")
    expectApply(seed, "The hoax, the shoal, a mipmap, pmic", "The hoax, the shoal, a mipmap, pmic")
    expectApply(seed, "ARMS and arms and armed", "ARMS and arms and armed")

    print("-- ARM only in clear mortgage context")
    expectApply(seed, "a 5/1 arm", "a 5/1 ARM")
    expectApply(seed, "a 7/6 arm loan", "a 7/6 ARM loan")
    expectApply(seed, "an adjustable rate arm", "an adjustable rate ARM")
    expectApply(seed, "an adjustable-rate arm", "an adjustable-rate ARM")
    expectApply(seed, "a hybrid arm", "a hybrid ARM")
    expectApply(seed, "my arm loan", "my ARM loan")
    expectApply(seed, "the arm index and arm margin", "the ARM index and ARM margin")
    expectApply(seed, "a five year arm", "a five year ARM")
    expectApply(seed, "a 5-year arm", "a 5-year ARM")
    expectApply(seed, "A R M loan", "ARM loan", "spelled-out A R M")
    expectApply(seed, "an ARM or 5/1 ARMs", "an ARM or 5/1 ARMs", "already-uppercase ARM is left as is")
    expectApply(seed, "She went 5/1 on the arm wrestle", "She went 5/1 on the arm wrestle", "5/1 not directly before 'arm'")

    print("-- month abbreviation vs APR")
    expectApply(seed, "We close Apr 3, Apr. 4 and apr 15th.", "We close Apr 3, Apr. 4 and apr 15th.")
    expectApply(seed, "the apr is 6.5%", "the APR is 6.5%")
    expectApply(seed, "6.5% apr", "6.5% APR")
    expectApply(seed, "Apr 6.5% fixed", "APR 6.5% fixed")
    expectApply(seed, "The APR is 7%.", "The APR is 7%.")

    print("-- numbers and punctuation untouched")
    expectApply(seed, "$350,000 at 6.5% for 30 years (3.25 points); call 555-1234, ext. 9!",
                "$350,000 at 6.5% for 30 years (3.25 points); call 555-1234, ext. 9!")
    expectApply(seed, "3 p.m. on 10/12 -- 1099-MISC and 1099s", "3 p.m. on 10/12 -- 1099-MISC and 1099s")
    expectApply(seed, "10 99 cents", "10 99 cents", "two separate numbers are not '1099'")
    expectApply(seed, "(dti), [ltv]; 'va' - \"heloc\"...", "(DTI), [LTV]; 'VA' - \"HELOC\"...")

    print("-- emails and web addresses untouched")
    expectApply(seed, "email dti@example.com or visit www.fha.gov and fha.gov/loans",
                "email dti@example.com or visit www.fha.gov and fha.gov/loans")
    expectApply(seed, "write sam@va.example.com about it", "write sam@va.example.com about it")
    expectApply(seed, "go to https://www.va.gov/home-loans now", "go to https://www.va.gov/home-loans now")
    expectApply(seed, "See fha.gov. Then the dti.", "See fha.gov. Then the DTI.")

    print("-- how the recognizer actually writes things (spelled out, closed up, split)")
    expectApply(seed, "T-R-I-D and R-E-S-P-A apply", "TRID and RESPA apply")
    expectApply(seed, "d t i is 41 and N M L S is on file", "DTI is 41 and NMLS is on file")
    expectApply(seed, "an F-H-A loan", "an FHA loan")
    expectApply(seed, "an F.H.A. loan", "an F.H.A. loan", "dotted spellings are left alone (the last dot may end a sentence)")
    expectApply(seed, "the A P R is high", "the APR is high")
    expectApply(seed, "the W2 and the w 2 and w-2 and W-2 and 1099 forms", "the W-2 and the W-2 and W-2 and W-2 and 1099 forms")
    expectApply(seed, "pre approval", "pre-approval")
    expectApply(seed, "Pre approval letter", "Pre-approval letter")
    expectApply(seed, "preapproval and a Pre-Approval", "pre-approval and a pre-approval")
    expectApply(seed, "debt to income ratio and loan to value", "debt-to-income ratio and loan-to-value")
    expectApply(seed, "I wrote a PR yesterday", "I wrote a PR yesterday", "'a PR' must not become APR")

    print("-- plurals and possessives")
    expectApply(seed, "two helocs and three DTIs", "two HELOCs and three DTIs")
    expectApply(seed, "the va's rules and FHA's limits", "the VA's rules and FHA's limits")

    print("-- replacement lines")
    expectApply(seed, "I spoke to fanny may and Freddie Mack.", "I spoke to Fannie Mae and Freddie Mac.")
    expectApply(seed, "Ernest money is due, he said ernest money.", "Earnest money is due, he said earnest money.")
    expectApply(seed, "a he lock is a second loan", "a HELOC is a second loan")
    expectApply(seed, "He locked the door.", "He locked the door.")
    expectApply(seed, "bring the w two", "bring the W-2")

    print("-- edge inputs")
    expectApply(seed, "", "")
    expectApply(seed, "   ", "   ")
    expectApply(seed, "café 🏠 dti ✓", "café 🏠 DTI ✓")
    expectApply(seed, "dti", "DTI")
    expectApply(seed, "line one\r\ndti\r\nltv", "line one\r\nDTI\r\nLTV")

    print("\n=== 1b. custom dictionary: names, homographs, explicit lines")
    expectApply(custom, "I will grant you a loan. Will called.", "I will grant you a loan. Will called.",
                "capitalized entries that are everyday words (Will, Grant) are left alone")
    expectApply(custom, "call grant smith tomorrow", "call Grant Smith tomorrow", "explicit line for a name that is also a word")
    expectApply(custom, "tell o'brien and O\u{2019}Brien", "tell O'Brien and O'Brien")
    expectApply(custom, "smith & sons or smith and sons", "Smith & Sons or smith and sons")
    expectApply(custom, "acme lending closed", "Acme Lending closed")
    expectApply(custom, "the cap is 2%", "the cap is 2%", "CAP is an everyday word: not enforced")
    expectApply(custom, "I hurt my arm", "I hurt my ARM", "an explicit 'arm -> ARM' line is always obeyed")
    expectApply(custom, "zorblax and Zorblax", "Zorblax and Zorblax")
}

// MARK: - 2. file behaviour

func runFileTests(workDir: URL, seedFile: URL) {
    print("\n=== 2. file behaviour")
    let fm = FileManager.default

    // Seeding
    let seed = PersonalDictionary(fileURL: seedFile)
    let text = (try? String(contentsOf: seedFile, encoding: .utf8)) ?? ""
    checkTrue("seeded file exists and starts with a # header", text.hasPrefix("# Verbaline personal dictionary"))
    let terms = seed.terms
    checkTrue("seed has 38-60 terms (got \(terms.count))", (38...60).contains(terms.count))
    checkTrue("no duplicate terms (ignoring case)", Set(terms.map { $0.lowercased() }).count == terms.count)
    checkTrue("no comment text leaked into terms", !terms.contains { $0.hasPrefix("#") })
    for must in ["DTI", "LTV", "HELOC", "non-QM", "TRID", "Fannie Mae", "Freddie Mac", "cash-out refinance",
                 "Loan Estimate", "Closing Disclosure", "earnest money", "W-2", "1099", "pre-approval", "escrow"] {
        checkTrue("seed term present: \(must)", terms.contains(must))
    }
    checkTrue("replacement left side is NOT a hint ('fanny may')", !terms.contains("fanny may"))
    checkTrue("replacement right side IS a hint ('Fannie Mae')", terms.contains("Fannie Mae"))
    print("  info  seed term count: \(terms.count)")

    // Never overwrite
    let existing = workDir.appendingPathComponent("existing.txt")
    try? "Zorblax\n".write(to: existing, atomically: true, encoding: .utf8)
    let d1 = PersonalDictionary(fileURL: existing)
    check("existing file is not overwritten (terms)", d1.terms.joined(separator: ","), "Zorblax")
    check("existing file is not overwritten (bytes)", (try? String(contentsOf: existing, encoding: .utf8)) ?? "?", "Zorblax\n")

    // Parent folder is created
    let nested = workDir.appendingPathComponent("a/b/c/dict.txt")
    _ = PersonalDictionary(fileURL: nested)
    checkTrue("missing parent folders are created", fm.fileExists(atPath: nested.path))

    // Saved as Rich Text by mistake: ignored, last good copy kept.
    let rtfFile = workDir.appendingPathComponent("rtf.txt")
    try? "alpha\n".write(to: rtfFile, atomically: true, encoding: .utf8)
    let drtf = PersonalDictionary(fileURL: rtfFile)
    try? "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0 bravo\\par}".write(to: rtfFile, atomically: true, encoding: .utf8)
    check("RTF file: markup is not treated as terms (last good copy kept)", drtf.terms.joined(separator: ","), "alpha")
    let rtfFirst = workDir.appendingPathComponent("rtf_first.txt")
    try? "{\\rtf1\\ansi bravo}".write(to: rtfFirst, atomically: true, encoding: .utf8)
    checkTrue("RTF file at startup: falls back to the built-in seed", PersonalDictionary(fileURL: rtfFirst).terms == seed.terms)
    try? "alpha\ncharlie\n".write(to: rtfFile, atomically: true, encoding: .utf8)
    check("RTF file: fixing it back to plain text is picked up", drtf.terms.joined(separator: ","), "alpha,charlie")

    // Cannot create the file: still works, from the built-in seed.
    let blocked = PersonalDictionary(fileURL: URL(fileURLWithPath: "/System/verbaline-no-such-place/dictionary.txt"))
    checkTrue("unwritable location: falls back to the built-in seed (\(blocked.terms.count) terms)", blocked.terms == seed.terms)
    check("unwritable location: apply() still works", blocked.apply(to: "your dti"), "your DTI")
    checkTrue("unwritable location: nothing was created", !fm.fileExists(atPath: "/System/verbaline-no-such-place"))

    // Parsing
    let entries = PersonalDictionary.parse("\u{FEFF}# comment\r\nDTI\r\n\r\n  fanny may   ->   Fannie  Mae \r\nold → New\r\nx => y\r\n -> nothing\r\nleft ->\r\n   \r\nlast")
    let want: [PersonalDictionary.Entry] = [
        .init(heard: nil, written: "DTI"),
        .init(heard: "fanny may", written: "Fannie Mae"),
        .init(heard: "old", written: "New"),
        .init(heard: "x", written: "y"),
        .init(heard: nil, written: "last"),
    ]
    checkTrue("parse: BOM, CRLF, comments, blanks, ->, →, =>, empty sides", entries == want, "got \(entries)")
    let long = String(repeating: "x", count: 200)
    checkTrue("parse: over-long line ignored", PersonalDictionary.parse("ok\n\(long)\nfine").map { $0.written } == ["ok", "fine"])

    // Reload on change
    let reload = workDir.appendingPathComponent("reload.txt")
    try? "alpha\n".write(to: reload, atomically: true, encoding: .utf8)
    let dr = PersonalDictionary(fileURL: reload)
    check("reload: initial", dr.terms.joined(separator: ","), "alpha")
    try? "alpha\nbravo\n".write(to: reload, atomically: true, encoding: .utf8)
    check("reload: appended line seen without re-init", dr.terms.joined(separator: ","), "alpha,bravo")
    // Same size, written straight away: must still be noticed (modification time has sub-second precision).
    try? "alpha\nCHARL\n".write(to: reload, atomically: true, encoding: .utf8)
    check("reload: same-size edit moments later is seen", dr.terms.joined(separator: ","), "alpha,CHARL")
    check("reload: apply() uses the new file too", dr.apply(to: "say charl"), "say CHARL")
    try? fm.removeItem(at: reload)
    check("reload: deleted file -> last good terms kept", dr.terms.joined(separator: ","), "alpha,CHARL")
    check("reload: deleted file -> apply() keeps working", dr.apply(to: "say charl"), "say CHARL")
    try? "# only comments now\n".write(to: reload, atomically: true, encoding: .utf8)
    check("reload: file recreated and emptied -> no terms", dr.terms.joined(separator: ","), "")
    check("reload: emptied file -> apply() is a no-op", dr.apply(to: "say charl dti"), "say charl dti")

    // Threads: readers and a rewriter at the same time must not crash or return garbage.
    let busy = workDir.appendingPathComponent("busy.txt")
    try? "DTI\nLTV\n".write(to: busy, atomically: true, encoding: .utf8)
    let db = PersonalDictionary(fileURL: busy)
    let bad = Tally()
    let group = DispatchGroup()
    let stop = StopFlag()
    for _ in 0..<6 {
        group.enter()
        DispatchQueue.global().async {
            while !stop.isSet {
                let out = db.apply(to: "the dti and the ltv")
                // Only the two states the file can be in are acceptable.
                bad.record(out == "the DTI and the LTV" || out == "the dti and the ltv" || out == "the DTI and the ltv")
                _ = db.terms
            }
            group.leave()
        }
    }
    for i in 0..<60 {
        try? (i % 2 == 0 ? "DTI\nLTV\n# \(i)\n" : "DTI\nLTV\n# \(i) longer\n").write(to: busy, atomically: true, encoding: .utf8)
        usleep(2000)
    }
    stop.set()
    group.wait()
    checkTrue("threads: 6 readers + 1 rewriter, no bad output (\(bad.passed) reads)", bad.failed == 0)

    // Speed
    let sample = "Your DTI is forty one percent and the LTV is eighty, so we can do a HELOC or a cash out refi through Fannie Mae. "
        + "Please send the loan estimate and the closing disclosure before the rate lock expires, and tell the underwriter about the gift letter."
    var t = nowMs()
    let n = 200
    for _ in 0..<n { _ = seed.apply(to: sample) }
    let seedMs = (nowMs() - t) / Double(n)
    t = nowMs()
    for _ in 0..<2000 { _ = seed.terms }
    let termsMs = (nowMs() - t) / 2000
    let big = workDir.appendingPathComponent("big.txt")
    var lines = ""
    for i in 0..<500 { lines += "Termname\(i) Zed\n" }
    try? lines.write(to: big, atomically: true, encoding: .utf8)
    let dbig = PersonalDictionary(fileURL: big)
    let longText = String(repeating: sample + " ", count: 8)   // ~2,000 characters
    t = nowMs()
    for _ in 0..<20 { _ = dbig.apply(to: longText) }
    let bigMs = (nowMs() - t) / 20
    print(String(format: "  info  apply(): %.3f ms for a %d-char sentence (%d seed terms); %.3f ms for %d chars with 500 terms; terms getter: %.4f ms",
                 seedMs, sample.count, seed.terms.count, bigMs, longText.count, termsMs))
    checkTrue("apply() is fast enough (<5 ms typical dictation, <50 ms for 2,000 chars with 500 terms)", seedMs < 5 && bigMs < 50)
    checkTrue("terms getter is cheap (<0.5 ms)", termsMs < 0.5)
}

/// Set-once flag for the thread test.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.withLock { v = true } }
    var isSet: Bool { lock.withLock { v } }
}

// MARK: - 3. vocabulary API

@available(macOS 26.0, *)
func runVocabularyTests() {
    print("\n=== 3. AppleTranscriber.vocabulary API")
    let t = AppleTranscriber()
    checkTrue("starts empty", t.vocabulary.isEmpty)

    t.vocabulary = ["  DTI ", "dti", "Fannie   Mae", "", "   ", "cash-out refinance", "DTI"]
    check("trims, collapses spaces, drops empties, dedupes ignoring case (keeps first)",
          t.vocabulary.joined(separator: "|"), "DTI|Fannie Mae|cash-out refinance")

    t.vocabulary = (0..<800).map { "Term\($0)" }
    check("capped at \(AppleTranscriber.maxVocabularyTerms) terms", "\(t.vocabulary.count)", "\(AppleTranscriber.maxVocabularyTerms)")

    t.vocabulary = ["ok", String(repeating: "x", count: AppleTranscriber.maxVocabularyTermLength + 1)]
    check("over-long entry dropped", t.vocabulary.joined(separator: "|"), "ok")

    t.vocabulary = []
    checkTrue("can be cleared", t.vocabulary.isEmpty)

    // Hammer from many threads; every read must be one of the lists that was written.
    let lists: [[String]] = [[], ["A"], ["A", "B"], ["A", "B", "C"]]
    let ok = Tally()
    let group = DispatchGroup()
    for w in 0..<8 {
        group.enter()
        DispatchQueue.global().async {
            for i in 0..<5000 {
                if (i + w) % 3 == 0 { t.vocabulary = lists[(i + w) % lists.count] }
                else { ok.record(lists.contains(t.vocabulary)) }
            }
            group.leave()
        }
    }
    group.wait()
    checkTrue("8 threads setting/reading at once: no crash, no torn reads (\(ok.passed) reads)", ok.failed == 0)
}

// MARK: - 4. speech comparison

struct Clip {
    let name: String
    let say: String
    /// Spellings the final text should contain, exactly (case-sensitive, whole word).
    let expected: [String]
}

let clips: [Clip] = [
    Clip(name: "c1", say: "Your D T I is forty one percent and the L T V is eighty, so we can do a heh lock or a cash out refi through Fannie Mae.",
         expected: ["DTI", "LTV", "HELOC", "cash-out refi", "Fannie Mae"]),
    Clip(name: "c2", say: "The borrower qualifies for an F H A loan with M I P, but we should compare a V A loan and a U S D A loan. Please send the Loan Estimate and the Closing Disclosure before the rate lock expires.",
         expected: ["FHA", "MIP", "VA", "USDA", "Loan Estimate", "Closing Disclosure", "rate lock"]),
    Clip(name: "c3", say: "This is a non Q M loan using D S C R. The underwriting team needs the appraisal, a gift letter, and the W 2 and ten ninety nine forms. Earnest money goes into escrow.",
         expected: ["non-QM", "DSCR", "underwriting", "appraisal", "gift letter", "W-2", "1099", "Earnest money", "escrow"]),
    Clip(name: "c4", say: "T R I D and R E S P A require the buyer to get the Loan Estimate within three business days. Our N M L S number is on the H M D A report. Freddie Mac conforming loans versus jumbo loans, and an A R M with a buydown, plus a pre approval letter.",
         expected: ["TRID", "RESPA", "Loan Estimate", "NMLS", "HMDA", "Freddie Mac", "ARM", "buydown", "pre-approval"]),
]

func ensureClip(_ clip: Clip, in dir: URL) -> URL? {
    let url = dir.appendingPathComponent("\(clip.name).wav")
    if FileManager.default.fileExists(atPath: url.path) { return url }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["--file-format=WAVE", "--data-format=LEI16@16000", "-o", url.path, clip.say]
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    return p.terminationStatus == 0 ? url : nil
}

func loadClip(_ url: URL, rate: Double = 16000) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let inFormat = file.processingFormat
    guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: inFormat, to: outFormat),
          let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: max(AVAudioFrameCount(file.length), 1)) else {
        throw NSError(domain: "dictionary_test", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot decode \(url.lastPathComponent)"])
    }
    try file.read(into: inBuffer)
    let cap = AVAudioFrameCount(Double(inBuffer.frameLength) * rate / inFormat.sampleRate) + 4096
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else {
        throw NSError(domain: "dictionary_test", code: 2, userInfo: [NSLocalizedDescriptionKey: "no output buffer"])
    }
    var supplied = false
    var error: NSError?
    converter.convert(to: outBuffer, error: &error) { _, status in
        if supplied { status.pointee = .endOfStream; return nil }
        supplied = true; status.pointee = .haveData; return inBuffer
    }
    if let error { throw error }
    guard let ch = outBuffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: ch, count: Int(outBuffer.frameLength)))
}

/// Which of `expected` appear in `text` exactly (case-sensitive, whole word).
func hits(_ text: String, _ expected: [String]) -> (found: [String], missed: [String]) {
    var found: [String] = [], missed: [String] = []
    for e in expected {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: e) + "(?![\\p{L}\\p{N}])"
        if text.range(of: pattern, options: .regularExpression) != nil { found.append(e) } else { missed.append(e) }
    }
    return (found, missed)
}

@available(macOS 26.0, *)
func runSpeechTests(dictionary: PersonalDictionary, outDir: URL, runs: Int, engines: [AppleTranscriber.Engine]) async {
    print("\n=== 4. speech comparison (vocabulary empty vs dictionary terms, then apply)")
    let terms = dictionary.terms
    print("dictionary terms handed to the recognizer: \(terms.count)")

    var wavs: [(Clip, URL, [Float])] = []
    for clip in clips {
        guard let url = ensureClip(clip, in: outDir), let samples = try? loadClip(url) else {
            print("  could not make/load clip \(clip.name); skipping"); continue
        }
        wavs.append((clip, url, samples))
    }
    guard !wavs.isEmpty else { print("no clips; skipping speech tests"); return }

    for engine in engines {
        print("\n----- engine: \(engine.rawValue)")
        let tr = AppleTranscriber(locale: Locale(identifier: "en-US"), engine: engine)
        do { try await tr.prepare() } catch { print("  prepare() failed (\(error)); skipping this engine"); continue }

        var scoreRaw = 0, scoreVocab = 0, scoreApplyOnVocab = 0, scoreApplyOnRaw = 0, total = 0
        var latencyDeltas: [Double] = []

        for (clip, _, samples) in wavs {
            let seconds = Double(samples.count) / 16000
            // Warm-up, then interleave modes so drift in machine load hits both equally.
            tr.vocabulary = []
            _ = try? await tr.transcribe(samples: samples, sampleRate: 16000)
            var rawTimes: [Double] = [], vocabTimes: [Double] = []
            var rawText = "", vocabText = ""
            for _ in 0..<max(runs, 1) {
                tr.vocabulary = []
                var t0 = nowMs()
                rawText = (try? await tr.transcribe(samples: samples, sampleRate: 16000)) ?? "<error>"
                rawTimes.append(nowMs() - t0)

                tr.vocabulary = terms
                t0 = nowMs()
                vocabText = (try? await tr.transcribe(samples: samples, sampleRate: 16000)) ?? "<error>"
                vocabTimes.append(nowMs() - t0)
            }
            let t0 = nowMs()
            let appliedVocab = dictionary.apply(to: vocabText)
            let applyMs = nowMs() - t0
            let appliedRaw = dictionary.apply(to: rawText)

            let hRaw = hits(rawText, clip.expected), hVocab = hits(vocabText, clip.expected)
            let hAV = hits(appliedVocab, clip.expected), hAR = hits(appliedRaw, clip.expected)
            total += clip.expected.count
            scoreRaw += hRaw.found.count; scoreVocab += hVocab.found.count
            scoreApplyOnVocab += hAV.found.count; scoreApplyOnRaw += hAR.found.count
            latencyDeltas.append(median(vocabTimes) - median(rawTimes))

            print(String(format: "\n  [%@] %.1f s of audio", clip.name, seconds))
            print("    said              : \(clip.say)")
            print("    1 no vocabulary   : \(rawText)")
            print("    2 with vocabulary : \(vocabText)")
            print("    3 vocabulary+apply: \(appliedVocab)")
            print("    4 no vocab + apply: \(appliedRaw)")
            print(String(format: "    terms right (of %d): 1=%d  2=%d  3=%d  4=%d    missed in 3: %@",
                         clip.expected.count, hRaw.found.count, hVocab.found.count, hAV.found.count, hAR.found.count,
                         hAV.missed.isEmpty ? "-" : hAV.missed.joined(separator: ", ")))
            print(String(format: "    latency median ms : no vocab %.0f  |  with vocab %.0f  |  delta %+.0f   (apply: %.2f ms)",
                         median(rawTimes), median(vocabTimes), median(vocabTimes) - median(rawTimes), applyMs))
        }

        print("\n  ==== \(engine.rawValue) summary: dictionary terms spelled exactly right, out of \(total)")
        print("       1 no vocabulary          : \(scoreRaw)")
        print("       2 vocabulary hints only  : \(scoreVocab)")
        print("       3 hints + apply()        : \(scoreApplyOnVocab)")
        print("       4 apply() only (no hints): \(scoreApplyOnRaw)")
        print(String(format: "       mean latency change from setting vocabulary: %+.1f ms", latencyDeltas.reduce(0, +) / Double(latencyDeltas.count)))

        // apply() must never make things worse than the raw text.
        checkTrue("[\(engine.rawValue)] apply() never loses a correct term (\(scoreApplyOnRaw) >= \(scoreRaw))", scoreApplyOnRaw >= scoreRaw)
        let meanDelta = latencyDeltas.reduce(0, +) / Double(latencyDeltas.count)
        if engine == .speech {
            // The engine the app ships with: setting a vocabulary must cost nothing noticeable.
            checkTrue("[speech] vocabulary does not noticeably slow transcription (mean delta \(String(format: "%+.1f", meanDelta)) ms < 25 ms)", meanDelta < 25)
        } else {
            // Not the shipping engine: report the cost, do not fail on it.
            print(String(format: "  info  [%@] vocabulary costs %+.0f ms on average here (reported, not a pass/fail)", engine.rawValue, meanDelta))
        }

        // Latency against list size, on the longest clip.
        if let longest = wavs.max(by: { $0.2.count < $1.2.count }) {
            let samples = longest.2
            print(String(format: "\n  latency vs vocabulary size, %@ (%.1f s of audio), median of %d runs:", longest.0.name, Double(samples.count) / 16000, max(runs, 1)))
            var row = "    terms:"
            var vals = "    ms   :"
            for size in [0, 5, 42, 200, 500] {
                var list = terms
                var i = 0
                while list.count < size { list.append("Filler\(i) Name"); i += 1 }
                tr.vocabulary = Array(list.prefix(size))
                _ = try? await tr.transcribe(samples: samples, sampleRate: 16000)   // warm-up
                var times: [Double] = []
                for _ in 0..<max(runs, 1) {
                    let t0 = nowMs()
                    _ = try? await tr.transcribe(samples: samples, sampleRate: 16000)
                    times.append(nowMs() - t0)
                }
                row += String(format: " %6d", size)
                vals += String(format: " %6.0f", median(times))
            }
            print(row); print(vals)
        }

        // Empty vocabulary must behave exactly like a transcriber that never had one.
        let fresh = AppleTranscriber(locale: Locale(identifier: "en-US"), engine: engine)
        try? await fresh.prepare()
        tr.vocabulary = ["x"]; tr.vocabulary = []
        let s = wavs[0].2
        let a = (try? await fresh.transcribe(samples: s, sampleRate: 16000)) ?? "<error>"
        let b = (try? await tr.transcribe(samples: s, sampleRate: 16000)) ?? "<error>"
        check("[\(engine.rawValue)] cleared vocabulary == never-set transcriber", b, a)

        // Timeout path still recovers with a vocabulary set.
        tr.vocabulary = terms
        setenv("VERBALINE_STT_TIMEOUT", "0.001", 1)
        var threw = false
        do { _ = try await tr.transcribe(samples: s, sampleRate: 16000) } catch { threw = true }
        unsetenv("VERBALINE_STT_TIMEOUT")
        let after = (try? await tr.transcribe(samples: s, sampleRate: 16000)) ?? "<error>"
        checkTrue("[\(engine.rawValue)] forced timeout with vocabulary set throws", threw)
        checkTrue("[\(engine.rawValue)] next call after the timeout works", !after.isEmpty && after != "<error>", "got \(after)")

        // Changing the vocabulary while a call is queued/running must not crash.
        async let one = tr.transcribe(samples: s, sampleRate: 16000)
        for i in 0..<200 { tr.vocabulary = i % 2 == 0 ? terms : [] }
        async let two = tr.transcribe(samples: s, sampleRate: 16000)
        let both = (try? await one, try? await two)
        checkTrue("[\(engine.rawValue)] changing vocabulary during queued calls is safe", both.0 != nil && both.1 != nil)
    }
}

// MARK: - main

@main
struct DictionaryTest {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let env = ProcessInfo.processInfo.environment
        let outDir = URL(fileURLWithPath: env["DICT_OUT"] ?? "build/dictionary_test", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("verbaline-dicttest-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // The seeded dictionary under test. A copy is saved next to the clips so you can read it.
        let seedFile = work.appendingPathComponent("seeded_dictionary.txt")
        let seed = PersonalDictionary(fileURL: seedFile)

        let customFile = work.appendingPathComponent("custom_dictionary.txt")
        try? """
        # extra entries used by the tests
        Will
        Grant
        CAP
        grant smith -> Grant Smith
        O'Brien
        Smith & Sons
        Acme Lending
        Zorblax
        arm -> ARM
        """.write(to: customFile, atomically: true, encoding: .utf8)
        let custom = PersonalDictionary(fileURL: customFile)

        runApplyTests(seed: seed, custom: custom)
        runFileTests(workDir: work, seedFile: work.appendingPathComponent("seed_for_file_tests.txt"))
        if #available(macOS 26.0, *) { runVocabularyTests() }

        if !args.contains("--skip-stt") {
            if #available(macOS 26.0, *) {
                let which = env["DICT_ENGINE"] ?? "both"
                let engines: [AppleTranscriber.Engine] = which == "speech" ? [.speech] : which == "dictation" ? [.dictation] : [.speech, .dictation]
                await runSpeechTests(dictionary: seed, outDir: outDir, runs: Int(env["DICT_RUNS"] ?? "") ?? 5, engines: engines)
            } else {
                print("\n(skipping speech tests: needs macOS 26)")
            }
        }

        if let data = try? Data(contentsOf: seedFile) {
            try? data.write(to: outDir.appendingPathComponent("seeded_dictionary.txt"))   // a copy to read; rewritten each run
        }

        let t = Tally.shared
        print("\n==== RESULT: \(t.passed) passed, \(t.failed) failed")
        exit(t.failed == 0 ? 0 : 1)
    }
}
