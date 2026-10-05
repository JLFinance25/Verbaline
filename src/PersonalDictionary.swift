import Foundation

// PersonalDictionary
// ------------------
// The user's own list of words and names (mortgage jargon, client names) that dictation should
// get exactly right. It is a plain text file the user edits in TextEdit.
//
// Public surface used by the app:
//     init(fileURL:)     -> creates the file with instructions + ~45 mortgage terms if it is missing
//     terms              -> hint strings for the recognizer (AppleTranscriber.vocabulary)
//     apply(to:)         -> fixes spelling/capitalization in a transcript
//
// Typical use, once per dictation:
//     transcriber.vocabulary = dictionary.terms
//     let raw = try await transcriber.transcribe(samples: s, sampleRate: r)
//     let text = dictionary.apply(to: raw)
//
// File format (one entry per line):
//     DTI                      a word/phrase written the way the user wants it to appear
//     fanny may -> Fannie Mae  explicit replacement: "what it heard" -> "what I want"
//     # note                   comment (also blank lines) -- ignored
//
// How apply(to:) stays safe (this is the important part):
//  * Whole words only, case-insensitive. "va" is never found inside "vacation" or "Nevada".
//  * Matching is relaxed about spaces/hyphens/slashes between the words of a phrase and about
//    letters spelled out, because the recognizer is inconsistent about them:
//    "non-QM" also fixes "non QM" and "nonqm"; "W-2" also fixes "W2" and "W 2";
//    "TRID" also fixes "T-R-I-D" and "T R I D". (The recognizer really does write "T-R-I-D" and
//    "W2".) Dotted forms like "T.R.I.D." are left alone. Plain English that merely sounds the
//    same is not touched.
//  * Words written in lowercase in the file ("escrow") are forced to lowercase mid-sentence and
//    keep whatever first letter they arrived with at the start of a sentence.
//  * Words with capitals in the file are written exactly as in the file ("Fannie Mae", "HELOC").
//  * Acronyms that are also everyday words are NOT enforced from the plain list. "ARM" only
//    becomes "ARM" when the neighbouring words say it is the loan ("5/1 arm", "adjustable rate
//    arm", "arm loan"), never in "I hurt my arm". The same goes for a capitalized entry that is an
//    everyday word (Will, Grant): left alone. The user can still force anything with an explicit
//    "heard -> written" line, which is always obeyed.
//  * "Apr 3" (the month) is not turned into "APR 3".
//  * Email addresses and web addresses are never edited. Numbers and punctuation are never touched
//    except when they are part of a dictionary entry (W-2).
//  * One pass over the original text: replaced text is never re-scanned, so apply(apply(x)) == apply(x).
//
// The file is re-read automatically when its modification date or size changes. If it
// disappears, cannot be read, or has been saved as Rich Text (RTF) by mistake, the last good
// version keeps being used.

final class PersonalDictionary: @unchecked Sendable {

    // MARK: - public API


    let fileURL: URL

    /// Creates the file with a commented header and seed terms if it does not exist.
    /// An existing file is never touched.
    init(fileURL: URL) {
        self.fileURL = fileURL
        self.snapshot = Snapshot(entries: [])
        Self.seedIfMissing(at: fileURL)
        if !refresh(force: true) {
            // Could not create or read the file (read-only disk, say): run on the built-in seed.
            lock.withLock { snapshot = Snapshot(entries: Self.parse(Self.seedText)) }
        }
    }

    /// Current terms: every plain entry plus the right-hand side of every replacement line, in file
    /// order, without duplicates. Reloaded automatically when the file changes; cheap to call
    /// before every dictation.
    var terms: [String] {
        refresh(force: false)
        return lock.withLock { snapshot.terms }
    }

    static let learnedHeader = "# ---- Learned from your edits (delete a line to forget it)"

    /// Adds a `heard -> written` line learned from one of the user's own fixes, under the learned
    /// heading at the bottom of the file. Returns false if that phrase already has a rule, the file
    /// isn't plain text, or it can't be written. Main thread.
    @discardableResult
    func learn(heard: String, written: String) -> Bool {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !written.isEmpty, !heard.contains("->"), !written.contains("->"),
              !heard.contains("\n"), !written.contains("\n") else { return false }
        var contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        if contents.hasPrefix("{\\rtf") { return false }
        if Self.parse(contents).contains(where: { $0.heard?.caseInsensitiveCompare(heard) == .orderedSame }) { return false }
        if !contents.isEmpty, !contents.hasSuffix("\n") { contents += "\n" }
        if !contents.contains(Self.learnedHeader) { contents += "\n" + Self.learnedHeader + "\n" }
        contents += Self.learnedLine(heard: heard, written: written) + "\n"
        do { try contents.write(to: fileURL, atomically: true, encoding: .utf8) } catch { return false }
        refresh(force: true)
        return true
    }

    /// Removes a line that `learn` added. Returns false if it isn't in the file anymore.
    @discardableResult
    func forget(heard: String, written: String) -> Bool {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        let target = Self.learnedLine(heard: heard.trimmingCharacters(in: .whitespacesAndNewlines),
                                      written: written.trimmingCharacters(in: .whitespacesAndNewlines))
        var lines = contents.components(separatedBy: "\n")
        guard let i = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == target }) else { return false }
        lines.remove(at: i)
        do { try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8) } catch { return false }
        refresh(force: true)
        return true
    }

    private static func learnedLine(heard: String, written: String) -> String {
        "\(heard.lowercased()) -> \(written)"
    }

    /// Fix the spelling/capitalization of dictionary terms in `text` and apply the replacement lines.
    /// See the header comment for exactly what is and is not touched.
    func apply(to text: String) -> String { applyReporting(to: text).text }

    /// Like `apply`, and also lists every word swap a `heard -> written` line made (what was there → what
    /// replaced it), so the app can show "Fixed …". Pure capitalization fixes of plain terms aren't listed.
    func applyReporting(to text: String) -> (text: String, swaps: [(from: String, to: String)]) {
        refresh(force: false)
        let rules = lock.withLock { snapshot.rules }
        guard !text.isEmpty, !rules.isEmpty else { return (text, []) }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let protected = Self.protectedRanges(in: text, full: full)

        var candidates: [Candidate] = []
        for rule in rules {
            rule.regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match else { return }
                let range = match.range
                if protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) { return }
                guard let replacement = Self.replacement(for: rule, match: match, in: ns) else { return }
                candidates.append(Candidate(range: range, replacement: replacement,
                                            isReplacementRule: rule.kind == .replacement, order: rule.order))
            }
        }
        guard !candidates.isEmpty else { return (text, []) }

        // Pick a non-overlapping set. Explicit replacement lines beat plain terms; then the longer
        // match wins; then the line lower down the file wins (so a correction added at the bottom works).
        candidates.sort {
            if $0.isReplacementRule != $1.isReplacementRule { return $0.isReplacementRule }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            if $0.order != $1.order { return $0.order > $1.order }
            return $0.range.location < $1.range.location
        }
        var chosen: [Candidate] = []
        for c in candidates where !chosen.contains(where: { NSIntersectionRange($0.range, c.range).length > 0 }) {
            chosen.append(c)
        }

        let swaps: [(from: String, to: String)] = chosen
            .filter { $0.isReplacementRule }
            .sorted { $0.range.location < $1.range.location }
            .map { (ns.substring(with: $0.range), $0.replacement) }
            .filter { $0.0 != $0.1 }
        let out = NSMutableString(string: text)
        for c in chosen.sorted(by: { $0.range.location > $1.range.location }) {
            out.replaceCharacters(in: c.range, with: c.replacement)
        }
        return (out as String, swaps)
    }

    // MARK: - state

    private struct FileStamp: Equatable {
        var modified: Date
        var size: Int
    }

    private let lock = NSLock()
    private var snapshot: Snapshot
    private var stamp: FileStamp?

    /// Re-read the file if it changed. Returns false only if there is still no usable file.
    @discardableResult
    private func refresh(force: Bool) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modified = attrs[.modificationDate] as? Date else {
            return lock.withLock { stamp != nil }   // file gone: keep the last good copy
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let current = FileStamp(modified: modified, size: size)
        if !force, lock.withLock({ stamp == current }) { return true }

        guard let data = try? Data(contentsOf: fileURL) else {
            return lock.withLock { stamp != nil }
        }
        let contents = String(decoding: data, as: UTF8.self)
        // Saved as Rich Text by mistake: that is markup, not a word list. Keep the last good copy
        // (the stamp is left alone so the file is looked at again on the next call).
        if contents.hasPrefix("{\\rtf") { return lock.withLock { stamp != nil } }
        let fresh = Snapshot(entries: Self.parse(contents))
        lock.withLock {
            snapshot = fresh
            stamp = current
        }
        return true
    }

    // MARK: - parsing

    struct Entry: Equatable {
        /// nil for a plain term line.
        var heard: String?
        var written: String
    }

    /// Lines longer than this are not words or names; skip them.
    private static let maxLineLength = 120
    private static let maxEntries = 2000

    /// Parse the text of a dictionary file. Exposed (internal) for the test harness.
    static func parse(_ contents: String) -> [Entry] {
        var text = contents
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }   // byte-order mark some editors add

        var entries: [Entry] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.count > maxLineLength { continue }

            if let (left, right) = splitReplacement(line) {
                let heard = collapseSpaces(left), written = collapseSpaces(right)
                if heard.isEmpty || written.isEmpty { continue }
                entries.append(Entry(heard: heard, written: written))
            } else {
                entries.append(Entry(heard: nil, written: collapseSpaces(line)))
            }
            if entries.count >= maxEntries { break }
        }
        return entries
    }

    /// Splits "heard -> written" (also accepts "→" and "=>") at the first arrow.
    private static func splitReplacement(_ line: String) -> (String, String)? {
        var best: Range<String.Index>?
        for arrow in ["->", "→", "=>"] {
            if let r = line.range(of: arrow), best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        guard let r = best else { return nil }
        return (String(line[..<r.lowerBound]), String(line[r.upperBound...]))
    }

    private static func collapseSpaces(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - compiled rules

    private enum RuleKind { case term, replacement }

    private struct Rule {
        let kind: RuleKind
        /// What to write.
        let written: String
        let regex: NSRegularExpression
        /// An everyday word that is also an acronym or name: only enforced with mortgage context.
        let isHomograph: Bool
        let order: Int
    }

    private struct Candidate {
        let range: NSRange
        let replacement: String
        let isReplacementRule: Bool
        let order: Int
    }

    private final class Snapshot {
        let terms: [String]
        let rules: [Rule]

        init(entries: [Entry]) {
            var rules: [Rule] = []
            var hints: [String] = []
            var seen = Set<String>()
            func addHint(_ s: String) {
                if seen.insert(s.lowercased()).inserted { hints.append(s) }
            }

            for (index, entry) in entries.enumerated() {
                if let heard = entry.heard {
                    guard let regex = PersonalDictionary.makeRegex(for: heard, allowsPlural: false) else { continue }
                    rules.append(Rule(kind: .replacement, written: entry.written, regex: regex,
                                      isHomograph: false, order: index))
                    addHint(entry.written)
                } else {
                    let homograph = PersonalDictionary.isHomograph(entry.written)
                    let plural = !homograph && PersonalDictionary.isAcronym(entry.written)
                    guard let regex = PersonalDictionary.makeRegex(for: entry.written, allowsPlural: plural) else { continue }
                    rules.append(Rule(kind: .term, written: entry.written, regex: regex,
                                      isHomograph: homograph, order: index))
                    addHint(entry.written)
                }
            }
            self.rules = rules
            self.terms = hints
        }
    }

    // MARK: - regex construction

    /// Characters that separate the words of a phrase and may be spaces, hyphens or slashes in the transcript.
    private static let separator = "[\\s\\-\u{2013}\u{2014}/]+"
    private static let wordChar = "[\\p{L}\\p{N}]"

    private static func escape(_ token: String) -> String {
        var out = ""
        for ch in token {
            if ch == "'" || ch == "\u{2019}" { out += "['\u{2019}]" }     // straight or curly apostrophe
            else { out += NSRegularExpression.escapedPattern(for: String(ch)) }
        }
        return out
    }

    /// Build the case-insensitive, whole-word pattern for a phrase. It accepts:
    ///   (a) the words in order, separated by any mix of spaces / hyphens / slashes
    ///   (b) for phrases of 2+ words, the words closed up ("preapproval", "w2", "nonqm")
    ///   (c) for 2-8 letter/digit entries, the letters spelled out ("D T I", "T-R-I-D"). Dotted forms
    ///       ("F.H.A.") are deliberately not matched: the last dot could be the end of the sentence.
    static func makeRegex(for phrase: String, allowsPlural: Bool) -> NSRegularExpression? {
        let tokens = phrase.split(whereSeparator: {
            $0.isWhitespace || $0 == "-" || $0 == "\u{2013}" || $0 == "\u{2014}" || $0 == "/"
        }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        var alternatives = [tokens.map(escape).joined(separator: separator)]
        let joined = tokens.joined()
        if tokens.count >= 2 { alternatives.append(escape(joined)) }

        let plainChars = joined.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        let letters = joined.filter { $0.isLetter }.count
        if plainChars, letters >= 2, (2...8).contains(joined.count) {
            let spelledSeparator = "[\\s\\-\u{2013}/]+"
            alternatives.append(joined.map { escape(String($0)) }.joined(separator: spelledSeparator))
        }

        let plural = allowsPlural ? "((?-i:s))?" : ""
        let pattern = "(?<!\(wordChar))(?:\(alternatives.joined(separator: "|")))\(plural)(?!\(wordChar))"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Letters/digits only, at least two letters, no lowercase: DTI, HELOC, W-2, FHA.
    private static func isAcronym(_ s: String) -> Bool {
        let letters = s.filter { $0.isLetter }
        return letters.count >= 2 && !s.contains(where: { $0.isLowercase })
    }

    /// A single-word entry that has a capital in it and is also an everyday English word (ARM, Will, Grant).
    private static func isHomograph(_ written: String) -> Bool {
        guard !written.contains(where: { $0.isWhitespace || $0 == "-" || $0 == "/" }),
              written.contains(where: { $0.isUppercase }) else { return false }
        return commonWords.contains(written.lowercased())
    }

    // MARK: - choosing the replacement text

    /// The text to put in place of `match`, or nil to leave it alone.
    private static func replacement(for rule: Rule, match: NSTextCheckingResult, in ns: NSString) -> String? {
        let range = match.range
        let matched = ns.substring(with: range)
        let pluralMatched = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
        let core = rule.written + (pluralMatched ? "s" : "")

        if rule.kind == .term {
            let termLower = rule.written.lowercased()
            if isMonthAbbreviation(termLower, at: range, in: ns) { return nil }
            if rule.isHomograph {
                // A multi-word match ("A R M") is spelled out on purpose. A single word needs context.
                let single = !matched.contains(where: { $0.isWhitespace || "-\u{2013}\u{2014}/.".contains($0) })
                if single && !hasMortgageContext(termLower, around: range, in: ns) { return nil }
            }
        }

        var result = core
        if !core.contains(where: { $0.isUppercase }) {
            // Written in lowercase in the file.
            if rule.kind == .term, isShoutedWord(matched) { return nil }   // "ESCROW", "ARM": the recognizer meant an acronym
            if let first = matched.first, first.isUppercase, isSentenceStart(at: range.location, in: ns) {
                result = core.prefix(1).uppercased() + core.dropFirst()
            }
        }
        return result == matched ? nil : result
    }

    /// Two or more letters, none lowercase.
    private static func isShoutedWord(_ s: String) -> Bool {
        s.filter { $0.isLetter }.count >= 2 && !s.contains(where: { $0.isLowercase })
    }

    /// True at the very start, after . ! ? or a line break, or right after an opening quote/bracket.
    private static func isSentenceStart(at location: Int, in ns: NSString) -> Bool {
        var i = location - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if c == 0x20 || c == 0x09 || c == 0xA0 { i -= 1; continue }
            switch c {
            case 0x2E, 0x21, 0x3F, 0x2026, 0x0A, 0x0D: return true                       // . ! ? … newline
            case 0x22, 0x201C, 0x2018, 0x28, 0x5B, 0x7B, 0xAB: return true               // " “ ‘ ( [ { «
            default: return false
            }
        }
        return true
    }

    // MARK: - context rules for look-alike words

    private static let numberWords: Set<String> = ["one", "two", "three", "five", "seven", "ten", "fifteen", "thirty"]
    private static let armAfter: Set<String> = [
        "loan", "loans", "mortgage", "mortgages", "rate", "rates", "product", "products",
        "program", "programs", "index", "margin", "payment", "payments",
    ]

    /// Only `arm` has context rules. Anything else that is a homograph is never enforced from the plain list.
    private static func hasMortgageContext(_ termLower: String, around range: NSRange, in ns: NSString) -> Bool {
        guard termLower == "arm" else { return false }

        let windowStart = max(0, range.location - 48)
        let before = ns.substring(with: NSRange(location: windowStart, length: range.location - windowStart))
        let afterStart = range.location + range.length
        let after = ns.substring(with: NSRange(location: afterStart, length: min(48, ns.length - afterStart)))

        if let g = firstGroups(of: contextBefore, in: before) {
            let p2 = g[0].lowercased(), p1 = g[1].lowercased()
            if p1 == "adjustable" || p1 == "hybrid" { return true }
            if p2 == "adjustable" && p1 == "rate" { return true }
            if ["year", "years", "yr", "yrs"].contains(p1), p2.allSatisfy({ $0.isNumber }) || numberWords.contains(p2) { return true }
        }
        if let g = firstGroups(of: contextBefore1, in: before) {
            let p1 = g[0]
            if p1.range(of: "^\\d+/\\d+$", options: .regularExpression) != nil { return true }   // 5/1, 7/6
            if p1.lowercased() == "adjustable" || p1.lowercased() == "hybrid" { return true }
        }
        if let g = firstGroups(of: contextAfter, in: after), armAfter.contains(g[0].lowercased()) { return true }
        return false
    }

    private static let contextBefore = try! NSRegularExpression(
        pattern: "([\\p{L}\\p{N}]+)[\\s\\-]+([\\p{L}\\p{N}]+)[\\s\\-]+$")
    private static let contextBefore1 = try! NSRegularExpression(
        pattern: "(\\d+/\\d+|[\\p{L}\\p{N}]+)[\\s\\-]+$")
    private static let contextAfter = try! NSRegularExpression(
        pattern: "^[\\s\\-]+([\\p{L}\\p{N}]+)")

    private static func firstGroups(of regex: NSRegularExpression, in s: String) -> [String]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }

    private static let dayNumberAfter = try! NSRegularExpression(
        pattern: "^\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?(?!\\d|\\.\\d|%)")

    /// "Apr 3" is the month, not the loan rate. ("APR 6.5%" and "your apr is" are still fixed.)
    private static func isMonthAbbreviation(_ termLower: String, at range: NSRange, in ns: NSString) -> Bool {
        guard termLower == "apr" else { return false }
        let afterStart = range.location + range.length
        let after = ns.substring(with: NSRange(location: afterStart, length: min(24, ns.length - afterStart)))
        return dayNumberAfter.firstMatch(in: after, options: [],
                                         range: NSRange(location: 0, length: (after as NSString).length)) != nil
    }

    // MARK: - text that must not be edited

    private static let protectedPattern = try! NSRegularExpression(pattern: [
        "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9\\-]+(?:\\.[A-Za-z0-9\\-]+)+",                                   // email address
        "(?:https?://|www\\.)[^\\s]+",                                                                  // web address
        "\\b[A-Za-z0-9\\-]+(?:\\.[A-Za-z0-9\\-]+)*\\.(?:com|org|net|gov|edu|io|co|us|app|info|biz)\\b(?:/[^\\s]*)?",  // bare domain
    ].joined(separator: "|"))

    private static func protectedRanges(in text: String, full: NSRange) -> [NSRange] {
        protectedPattern.matches(in: text, options: [], range: full).map { $0.range }
    }

    // MARK: - everyday words that must not be enforced as acronyms or names

    /// Deliberately small, hand-made list (not a dictionary): short everyday words an acronym or
    /// a first name could collide with. Only matters for entries that contain a capital letter.
    private static let commonWords: Set<String> = [
        // short words and acronym collisions
        "arm", "arms", "art", "all", "any", "are", "age", "air", "and", "ark", "ask", "bad", "bed", "big",
        "bit", "box", "boy", "buy", "can", "cap", "car", "cat", "cut", "day", "did", "die", "dog", "due",
        "end", "era", "far", "fax", "fee", "few", "fit", "fix", "fly", "for", "fun", "gap", "get", "god",
        "got", "gun", "guy", "has", "hat", "her", "hid", "him", "his", "hit", "hot", "how", "ice", "ill",
        "its", "job", "key", "kid", "law", "lay", "led", "leg", "let", "lie", "lot", "low", "man", "map",
        "may", "men", "met", "mix", "mom", "new", "nor", "not", "now", "nut", "oil", "old", "one", "our",
        "out", "own", "pay", "per", "pet", "pop", "put", "ran", "raw", "red", "rid", "row", "run", "sad",
        "say", "sea", "see", "set", "she", "shy", "sit", "six", "sky", "son", "sum", "sun", "tax", "tea",
        "ten", "the", "tie", "tip", "too", "top", "toy", "try", "two", "use", "van", "war", "was", "way",
        "web", "wet", "who", "why", "win", "won", "yes", "yet", "you", "zip", "is", "it", "in", "on", "or",
        "us", "me", "my", "we", "he", "so", "to", "no", "of", "if", "at", "as", "an", "am", "be", "by",
        "do", "go", "up", "id", "ok", "pr", "hi", "oh",
        // mortgage-flavoured everyday words
        "rate", "rates", "lock", "loan", "note", "term", "lien", "draw", "deed", "title", "fixed", "bond",
        "point", "points", "close", "closing", "cash", "home", "house", "free", "prime", "index", "margin",
        // first names and surnames that are also words
        "will", "grant", "mark", "bill", "bob", "hope", "grace", "rose", "joy", "faith", "summer", "dawn",
        "pat", "ray", "rich", "sue", "page", "long", "young", "brown", "white", "green", "black", "stone",
        "hill", "lane", "wood", "ford", "hunt", "cook", "baker", "miles", "frank", "jack", "jim", "rob",
        "max", "ben", "don", "gene", "guy", "mike", "sam", "tom", "tim", "tony", "chase", "dean", "drew",
    ]

    // MARK: - seeding

    private static func seedIfMissing(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // .withoutOverwriting: if two copies of the app start at once, the loser leaves the file alone.
        try? Data(seedText.utf8).write(to: url, options: [.withoutOverwriting])
    }

    /// The text of a brand-new dictionary file.
    static let seedText = """
    # Verbaline personal dictionary
    # =============================
    # Words and names you say often, so Verbaline gets them exactly right.
    # Edit this file in TextEdit, save it, and your next dictation uses the changes. No restart needed.
    #
    # WHAT IT DOES
    #  1. After every dictation, Verbaline fixes the spelling and capital letters of the words below.
    #     It ignores capitals and is relaxed about spaces and hyphens, so the line "cash-out refinance"
    #     also fixes "Cash Out Refinance", and the line "non-QM" also fixes "non QM" and "nonqm".
    #     Only whole words are matched ("arm" is never touched inside "farm"), and numbers and
    #     punctuation are left alone.
    #  2. The words are also passed to the speech recognizer as hints. How much a hint helps depends on
    #     the recognizer Verbaline is using; the fixes in step 1 always happen.
    #
    # HOW TO ADD THINGS
    #  - One word or phrase per line, written exactly the way you want it to appear:
    #        DTI
    #        Fannie Mae
    #        cash-out refinance
    #  - If Verbaline keeps mishearing something, write what it heard, then ->, then what you want:
    #        fanny may -> Fannie Mae
    #    The right-hand side is also used as a recognizer hint.
    #  - Lines that start with # and empty lines are ignored.
    #
    # GOOD TO KNOW
    #  - A word written in lowercase here (like escrow) stays lowercase in the middle of a sentence.
    #    A word with capitals here (like Fannie Mae or HELOC) always comes out exactly as written.
    #  - Some acronyms are also everyday words. ARM is only capitalized when the words next to it make
    #    clear you mean the loan ("5/1 arm", "adjustable rate arm", "arm loan"), so "I hurt my arm" is safe.
    #  - If you add a name that is also an everyday word (like Grant or Will), Verbaline leaves that
    #    word alone, because it cannot tell the name from the word. Use a longer line instead:
    #        grant smith -> Grant Smith
    #  - A "heard -> written" line is always obeyed, even for everyday words. Use it with care.

    # ---- Loan types and programs
    FHA
    VA
    USDA
    HELOC
    ARM
    DSCR
    non-QM
    jumbo loan
    conforming loan
    cash-out refinance
    cash-out refi
    buydown

    # ---- Numbers and ratios
    DTI
    LTV
    CLTV
    APR
    PMI
    MIP
    PITI
    FICO
    debt-to-income
    loan-to-value
    mortgage insurance
    amortization

    # ---- Rules and agencies
    TRID
    RESPA
    HMDA
    NMLS
    Fannie Mae
    Freddie Mac

    # ---- Documents and steps
    Loan Estimate
    Closing Disclosure
    W-2
    1099
    gift letter
    HOA
    pre-approval
    rate lock
    escrow
    earnest money
    underwriting
    appraisal

    # ---- Fix common mishearings: what it heard -> what you want
    fanny may -> Fannie Mae
    fannie may -> Fannie Mae
    fanny mae -> Fannie Mae
    freddy mac -> Freddie Mac
    freddie mack -> Freddie Mac
    ernest money -> earnest money
    he lock -> HELOC
    helllock -> HELOC
    hellock -> HELOC
    helock -> HELOC
    w two -> W-2

    """
}
