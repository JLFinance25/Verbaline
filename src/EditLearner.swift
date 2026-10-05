import AppKit

// EditLearner
// -----------
// After Verbaline pastes a dictation, another component watches that text box and, about a minute
// later, hands this file two strings: what Verbaline pasted, and the same region after the user
// edited it. This file decides which of those edits are SPEECH-RECOGNITION MISHEARINGS worth
// learning, so the personal dictionary can fix them next time ("heard -> written", whole phrase,
// case-insensitive, applied to every future dictation) -- and rejects everything else.
//
// Public surface:
//     EditLearner.corrections(pasted:edited:) -> [Correction]     (main thread only, at most 3)
//
// The one design rule: a wrongly learned rule silently corrupts every future dictation, so
// PRECISION BEATS RECALL. Every doubt means "learn nothing". Pipeline:
//
//  1. Words. Both strings are split on whitespace (em/en dashes too). Punctuation around a word is
//     ignored and case is ignored for alignment; results keep the original casing and lose the
//     surrounding punctuation. Pure-punctuation tokens ("-", "...") are not words.
//  2. Diff. Classic longest-common-subsequence over the words. A run of removed words next to a
//     run of added words is ONE replacement block ("Fanny May" -> "Fannie Mae" is one phrase).
//     Pure insertions and pure deletions are never learned. Words that match but differ only in
//     case are checked separately (step 5).
//  3. Rewrite guard. Reject EVERYTHING if there are more than 3 replacement blocks, or if the
//     changed words exceed max(3, 30% of the pasted words). Typing that simply continues after the
//     pasted text (or starts before it) is not counted: that is the user writing, not rewriting.
//  4. Per block (all must hold, otherwise that block is skipped):
//     a. heard 1-3 words. If the user kept typing right after the fix, the written side is
//        trimmed to its best-matching 1-3 word span from the block start; the rest is ignored.
//     b. no digits (numbers are content), no e-mail/URL, no symbols inside a word; no
//        comma/period between the words of the phrase.
//     c. is it a MISHEARING? Every word is sorted by what NSSpellChecker (English) says:
//          everyday  lowercase form is a real word          mortgage, may, there, Monday
//          name      only real when capitalized             Fannie, Mae, Sarah, Zhang, Nicholson
//          unknown   not a word at all                      Helllock, Nikolsen, HELOC, DTI, QM
//        (ALL-CAPS words count as unknown unless their lowercase is a word, because the checker
//        accepts any all-caps string: it says "XQZV" is fine.)
//          - both sides everyday                      -> reject (an edit, not a mishearing)
//          - heard is ONE everyday word               -> reject (rule would fire on normal text)
//          - name <-> name                            -> reject (a different person/place)
//          - everyday -> name   Fanny May -> Fannie Mae     learn (if similar)
//          - name -> everyday   Ernest -> earnest           learn, but only if the written word
//                                                           is lowercase (a capital = a name swap)
//          (when no word is unknown, the sound-alike bar is raised from 0.60 to 0.75; when the
//          number of words changes it is at least 0.70)
//          - anything with an unknown word            -> continue to the checks below
//        Written unknown words must look like a term (a capital somewhere): a lowercase non-word
//        is more likely a typo than something to teach. A heard acronym is never turned into a
//        non-acronym. Heard phrases made only of everyday words must not contain a very common
//        function word (the, you, he ...) unless the written side is a short acronym.
//     d. sounds alike (rule 7 in the brief), see `similarity`.
//     e. not just an ending change (HELOC -> HELOCs, Nikolsen -> Nikolsen's).
//  5. Case-only changes (heloc -> HELOC): learned only when the heard form is not a real word,
//     the new form has more capitals, an all-caps result is a plausible acronym (2-5 letters),
//     a first-letter-only capital is a known proper noun (sarah -> Sarah) and not the start of a
//     sentence, the word is not next to another edit, and fewer than 4 words changed case.
//  6. Deduplicate; if one heard phrase was fixed two different ways, drop both; return at most 3
//     in document order.
//
// What NSSpellChecker actually does (measured on macOS 26, language "en"):
//   * every all-caps string is "fine" (HELOC, DTI, LTV, NMLS, even XQZV), the lowercase ones are
//     not (heloc, dti, ltv, nmls are misspellings; va, fico too). So all-caps needs a lowercase check.
//   * capitalized proper nouns are fine, their lowercase forms usually not: Sarah/sarah,
//     Zhang/zhang, Fannie/fannie, Mae/mae, Nicholson/nicholson, Monday/monday, Jessica/jessica.
//   * Some unusual names are flagged capitalized but accepted in lowercase (the checker's word list
//     varies by Mac). Anything the checker accepts in lowercase is treated as everyday, which is the
//     safe direction.
//   * Results can differ on another Mac (other language packs, learned words); the test harness
//     starts with "ground truth" checks that fail loudly if the assumptions above stop holding.
//   * With no language given it is far more lenient ("Helllock" passes); so "en" is always passed.
//     If no English dictionary exists, nothing is ever learned.
//
// Known gaps (deliberate):
//   * Spelled-out acronyms of 4+ letters ("H E L O C", 5 words) exceed the 3-word block limit.
//   * Names that differ by a letter and are both unknown to the checker cannot be told from a
//     mishearing (Hamel -> Hammel is learned).
//   * Heard name -> similar lowercase everyday word is learned as written (Ernest -> earnest, as
//     the brief asks), so "Mary" -> "marry" would be learned too and then hit every real Mary.
//   * A snapshot taken while the user is still typing the fix can look like a complete fix
//     ("Fannie" typed on the way to "Fannie Mae" is judged by length ratio and similarity only).
//     The caller should only hand over text that has stopped changing.
//   * 3-letter and shorter phrases need a 0.80 match, so one-letter fixes there are not learned.

enum EditLearner {

    struct Correction: Equatable {
        let heard: String     // as the recognizer wrote it, e.g. "Helllock" or "Fanny May"
        let written: String   // as the user fixed it, e.g. "HELOC" or "Fannie Mae"
    }

    /// Which edits to the pasted text are mishearings worth learning? Main thread only
    /// (NSSpellChecker); called from any other thread it returns []. At most 3 results, in the
    /// order they appear in the text.
    static func corrections(pasted: String, edited: String) -> [Correction] {
        guard Thread.isMainThread else { return [] }
        let a = tokenize(pasted)
        let b = tokenize(edited)
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= maxDiffCells else { return [] }

        let diff = align(a, b)
        if diff.blocks.isEmpty && diff.caseDiffs.isEmpty { return [] }
        let n = a.count, m = b.count

        // Replacement blocks (both sides non-empty) and how many words changed in total.
        var replacements: [(block: Block, span: Int?)] = []
        var changed = 0
        for blk in diff.blocks {
            let hc = blk.h.count, wc = blk.w.count
            if hc == 0 {
                // Pure insertion. Typing at either end of the text is the user writing on,
                // not rewriting what was dictated.
                let atStart = blk.h.lowerBound == 0 && blk.w.lowerBound == 0
                let atEnd = blk.h.upperBound == n && blk.w.upperBound == m
                if !atStart && !atEnd { changed += wc }
            } else if wc == 0 {
                changed += hc                                    // pure deletion
            } else {
                let span = bestSpan(heard: Array(a[blk.h]), written: Array(b[blk.w]))?.k
                replacements.append((blk, span))
                var used = wc
                if blk.h.upperBound == n && blk.w.upperBound == m, let k = span { used = k }
                changed += max(hc, used)                         // rest of a tail block = typing on
            }
        }
        if replacements.count > maxReplacementBlocks { return [] }
        if Double(changed) > max(Double(rewriteFloorWords), rewriteFraction * Double(n)) { return [] }
        if replacements.isEmpty && diff.caseDiffs.isEmpty { return [] }

        let speller = Speller()
        guard speller.isAvailable else { return [] }

        var found: [(at: Int, correction: Correction)] = []

        for (blk, span) in replacements {
            guard let k = span else { continue }
            let written = Array(b[blk.w])
            if let c = evaluate(heard: Array(a[blk.h]), written: written, span: k, speller) {
                found.append((blk.h.lowerBound, c))
            }
        }

        // Matched words that differ only in capitalization. Bulk re-casing (select all +
        // UPPERCASE, title-casing a heading) is not a mishearing signal.
        if !diff.caseDiffs.isEmpty && diff.caseDiffs.count <= maxCaseOnlyChanges {
            // A re-cased word that touches an insertion/deletion/replacement may just be the
            // diff pairing a word with a copy of itself ("the heloc" -> "the HELOC heloc").
            var nextToEdit = Set<Int>()                    // pasted indices adjacent to a block
            for blk in diff.blocks {
                nextToEdit.insert(blk.h.lowerBound - 1)
                nextToEdit.insert(blk.h.upperBound)
            }
            for (i, j) in diff.caseDiffs where !nextToEdit.contains(i) {
                if let c = caseOnly(heard: a[i], written: b[j], speller) { found.append((i, c)) }
            }
        }

        found.sort { $0.at < $1.at }

        // Dedupe. The same heard phrase fixed two different ways is ambiguous: learn neither.
        var byHeard: [String: [Correction]] = [:]
        var order: [String] = []
        for (_, c) in found {
            let key = c.heard.lowercased()
            if byHeard[key] == nil { order.append(key) }
            if !(byHeard[key] ?? []).contains(c) { byHeard[key, default: []].append(c) }
        }
        var result: [Correction] = []
        for key in order {
            if let list = byHeard[key], list.count == 1 { result.append(list[0]) }
        }
        return Array(result.prefix(maxCorrections))
    }

    // MARK: - tunables (see the header for why)

    private static let maxCorrections = 3
    private static let maxBlockWords = 3
    private static let maxReplacementBlocks = 3
    private static let rewriteFloorWords = 3
    private static let rewriteFraction = 0.30
    private static let maxCaseOnlyChanges = 3
    private static let maxAcronymLetters = 5
    private static let maxDiffCells = 4_000_000
    /// Minimum similarity (scale 0...1.2, see `similarity`) for phrases of 5+ letters / shorter ones.
    private static let minSimilarity = 0.60
    private static let minSimilarityShort = 0.80
    /// Stricter bar when everyday words were rewritten as a capitalized non-word ("the man" -> "Themann").
    private static let minSimilarityCommonToUnknown = 0.80
    /// When every word on both sides is one the checker knows (Fanny May -> Fannie Mae, Ernest ->
    /// earnest) the only evidence is how it sounds, so it has to be a near-homophone.
    private static let minSimilarityAllKnown = 0.75
    /// When the number of words changes (1 -> 2 or 2 -> 1) the alignment is a guess.
    private static let minSimilarityWordCountChange = 0.70

    // MARK: - words

    private struct Token {
        let raw: String            // as typed, between whitespace
        let core: String           // raw without punctuation around it (original casing)
        let key: String            // lowercased core, straight apostrophes: used for alignment
        let leading: String        // punctuation stripped from the front
        let trailing: String       // punctuation stripped from the back
        let sentenceStart: Bool    // first word of the text, of a line, or right after . ! ?
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private static func straight(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var newlineBefore = false
        var prevEndedSentence = true

        func flush() {
            guard !current.isEmpty else { return }
            let chars = Array(current)
            let raw = current
            current = ""
            var lo = 0, hi = chars.count
            while lo < hi, !isWordChar(chars[lo]) { lo += 1 }
            while hi > lo, !isWordChar(chars[hi - 1]) { hi -= 1 }
            if lo >= hi { return }                       // "-", "•", "..." : not a word
            let core = String(chars[lo..<hi])
            let trailing = String(chars[hi...])
            tokens.append(Token(raw: raw,
                                core: core,
                                key: straight(core).lowercased(),
                                leading: String(chars[..<lo]),
                                trailing: trailing,
                                sentenceStart: tokens.isEmpty || newlineBefore || prevEndedSentence))
            newlineBefore = false
            prevEndedSentence = trailing.contains { ".!?".contains($0) }
        }

        for ch in text {
            if ch.isWhitespace {
                if ch.isNewline { newlineBefore = true }
                flush()
            } else if ch == "\u{2014}" || ch == "\u{2013}" {
                flush()
            } else {
                current.append(ch)
            }
        }
        flush()
        return tokens
    }

    // MARK: - diff

    private struct Block {
        let h: Range<Int>     // removed words (indices into the pasted tokens)
        let w: Range<Int>     // added words (indices into the edited tokens)
    }

    /// LCS alignment on keys. Returns the changed blocks and the matched pairs whose spelling
    /// differs only by case.
    private static func align(_ a: [Token], _ b: [Token]) -> (blocks: [Block], caseDiffs: [(Int, Int)]) {
        let n = a.count, m = b.count
        var ids: [String: Int] = [:]
        func id(_ k: String) -> Int {
            if let v = ids[k] { return v }
            let v = ids.count
            ids[k] = v
            return v
        }
        let ak = a.map { id($0.key) }
        let bk = b.map { id($0.key) }

        let w = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if ak[i] == bk[j] {
                        table[i * w + j] = table[(i + 1) * w + j + 1] + 1
                    } else {
                        table[i * w + j] = max(table[(i + 1) * w + j], table[i * w + j + 1])
                    }
                }
            }
        }

        var blocks: [Block] = []
        var caseDiffs: [(Int, Int)] = []
        var i = 0, j = 0
        var open: (Int, Int)? = nil
        func close() {
            if let (hs, ws) = open {
                blocks.append(Block(h: hs..<i, w: ws..<j))
                open = nil
            }
        }
        while i < n || j < m {
            if i < n && j < m && ak[i] == bk[j] {
                close()
                if a[i].core != b[j].core { caseDiffs.append((i, j)) }
                i += 1; j += 1
            } else {
                if open == nil { open = (i, j) }
                if j == m { i += 1 }
                else if i == n { j += 1 }
                else if table[(i + 1) * w + j] >= table[i * w + j + 1] { i += 1 }
                else { j += 1 }
            }
        }
        close()
        return (blocks, caseDiffs)
    }

    // MARK: - spell checker

    private enum Kind { case everyday, name, unknown }

    private final class Speller {
        private let checker = NSSpellChecker.shared
        private let tag = NSSpellChecker.uniqueSpellDocumentTag()
        private let language: String?
        private var cache: [String: Bool] = [:]

        init() {
            let langs = NSSpellChecker.shared.availableLanguages
            language = langs.contains("en") ? "en" : langs.first { $0.hasPrefix("en") }
        }

        deinit { checker.closeSpellDocument(withTag: tag) }

        var isAvailable: Bool { language != nil }

        /// True if the checker accepts `word` exactly as written (case matters to it).
        func accepts(_ word: String) -> Bool {
            guard let language = language else { return false }
            if let hit = cache[word] { return hit }
            let range = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                              inSpellDocumentWithTag: tag, wordCount: nil)
            let ok = range.location == NSNotFound
            cache[word] = ok
            return ok
        }
    }

    private static let calendarWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "june", "july", "august", "september",
        "october", "november", "december",
    ]

    private static func isAllCaps(_ s: String) -> Bool {
        let letters = s.filter { $0.isLetter }
        return letters.count >= 2 && !letters.contains { $0.isLowercase }
    }

    private static func kindOfWord(_ word: String, _ sp: Speller) -> Kind {
        let w = straight(word)
        let letters = w.filter { $0.isLetter }
        if letters.count <= 1 { return .everyday }                       // I, a, D, T ...
        let lower = w.lowercased()
        if calendarWords.contains(lower) { return .everyday }            // closed class
        if isAllCaps(w) { return sp.accepts(lower) ? .everyday : .unknown }
        if letters.dropFirst().contains(where: { $0.isUppercase }) {     // DocuSign, McDonald ...
            return (sp.accepts(w) && sp.accepts(lower)) ? .everyday : .unknown
        }
        if !sp.accepts(w) { return .unknown }
        return sp.accepts(lower) ? .everyday : .name
    }

    private static func kind(of token: Token, _ sp: Speller) -> Kind {
        var base = straight(token.core)
        if base.lowercased().hasSuffix("'s") { base.removeLast(2) }       // Nikolsen's -> Nikolsen
        if base.contains("-") {
            let inner = base.dropFirst().contains { $0.isUppercase }
            if !inner && sp.accepts(base.lowercased()) && sp.accepts(base) { return .everyday }  // pre-approval
        }
        var result = Kind.everyday
        for part in base.split(separator: "-") {
            switch kindOfWord(String(part), sp) {
            case .unknown: return .unknown
            case .name: result = .name
            case .everyday: break
            }
        }
        return result
    }

    /// Any all-caps part of at least two letters the checker does not know as a word (HELOC, QM).
    private static func hasUnknownAcronym(_ token: Token, _ sp: Speller) -> Bool {
        for part in straight(token.core).split(separator: "-") where isAllCaps(String(part)) {
            if kindOfWord(String(part), sp) == .unknown { return true }
        }
        return false
    }

    private static func hasAllCapsPart(_ token: Token) -> Bool {
        token.core.split(separator: "-").contains { isAllCaps(String($0)) }
    }

    // MARK: - token hygiene

    private static let linkSuffixes: Set<String> = [
        "com", "net", "org", "edu", "gov", "io", "co", "us", "ai", "app", "biz", "info", "me",
    ]

    private static func looksLikeLink(_ raw: String) -> Bool {
        let low = raw.lowercased()
        if low.contains("@") || low.contains("://") || low.contains("www.") { return true }
        let parts = low.split(separator: ".")
        if parts.count >= 2, let last = parts.last {
            let tld = String(last.prefix { $0.isLetter })
            if linkSuffixes.contains(tld) && parts.dropLast().allSatisfy({ !$0.isEmpty }) { return true }
        }
        return false
    }

    /// Letters, apostrophes and hyphens only: no digits, no symbols, no dots inside the word.
    private static func isPlainWord(_ core: String) -> Bool {
        core.contains { $0.isLetter } && core.allSatisfy { $0.isLetter || $0 == "'" || $0 == "\u{2019}" || $0 == "-" }
    }

    /// A phrase may not have a comma, period or bracket between its words.
    private static func isCleanSpan(_ span: [Token]) -> Bool {
        for (i, t) in span.enumerated() {
            if !isPlainWord(t.core) { return false }
            if i < span.count - 1 && !t.trailing.isEmpty { return false }
            if i > 0 && !t.leading.isEmpty { return false }
        }
        return true
    }

    private static func lettersOnly(_ tokens: [Token]) -> [Character] {
        tokens.flatMap { $0.core.lowercased().filter { $0.isLetter } }
    }

    // MARK: - similarity

    private static let letterNames: [String: Character] = [
        "a": "a", "ay": "a", "b": "b", "bee": "b", "c": "c", "cee": "c", "see": "c", "sea": "c",
        "d": "d", "dee": "d", "e": "e", "ee": "e", "f": "f", "ef": "f", "eff": "f", "g": "g", "gee": "g",
        "h": "h", "aitch": "h", "i": "i", "eye": "i", "aye": "i", "j": "j", "jay": "j", "k": "k", "kay": "k",
        "l": "l", "el": "l", "ell": "l", "m": "m", "em": "m", "n": "n", "en": "n", "o": "o", "oh": "o",
        "p": "p", "pee": "p", "pea": "p", "q": "q", "cue": "q", "queue": "q", "r": "r", "ar": "r",
        "s": "s", "es": "s", "ess": "s", "t": "t", "tee": "t", "tea": "t", "u": "u", "v": "v", "vee": "v",
        "w": "w", "x": "x", "ex": "x", "y": "y", "wye": "y", "why": "y", "z": "z", "zee": "z", "zed": "z",
    ]

    /// Spoken letter names that nobody means as ordinary words in this context.
    private static let distinctiveLetterNames: Set<String> = [
        "dee", "cee", "gee", "jay", "kay", "ell", "ef", "eff", "ess", "aitch", "vee", "zee", "zed",
        "wye", "pee", "tee", "cue", "em", "en", "ex", "ar",
    ]

    /// "Dee Tee Eye" -> DTI, "D T I" -> DTI: every heard word is a letter name or a single letter,
    /// at least two of them unmistakable, and together they spell the acronym.
    private static func spellsAcronym(heard: [Token], written: [Token]) -> Bool {
        guard written.count == 1 else { return false }
        let acronym = written[0].core
        guard (2...maxAcronymLetters).contains(acronym.count),
              acronym.allSatisfy({ $0.isLetter && $0.isUppercase }) else { return false }
        var spelled = ""
        var distinctive = 0
        for t in heard {
            let w = t.key
            guard let letter = letterNames[w] else { return false }
            spelled.append(letter)
            if distinctiveLetterNames.contains(w) || (w.count == 1 && w != "a" && w != "i") { distinctive += 1 }
        }
        return spelled == acronym.lowercased() && distinctive >= 2
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [Int](repeating: 0, count: b.count + 1)
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    private static func editSimilarity(_ a: [Character], _ b: [Character]) -> Double {
        let longest = max(a.count, b.count)
        return longest == 0 ? 1 : 1 - Double(levenshtein(a, b)) / Double(longest)
    }

    /// How alike two phrases are, letters only. 1.2 = same letters (spacing/hyphen/case aside) or
    /// spoken letter names of the acronym. 0 = the written side is a truncation of the heard side,
    /// or too different in length (see below). Otherwise plain edit similarity (1 - edits/longer
    /// length) plus 0.05 per shared leading letter (up to 4): recognizers usually get the start of
    /// a word right. Threshold 0.60 (0.80 when both phrases are under 5 letters).
    /// Measured on the brief's examples:
    ///   Helllock->HELOC 0.78   he lock->HELOC 0.93   Nicholson->Nikolsen   Fanny May->Fannie Mae 0.87
    ///   Ernest->earnest 0.91   non QM->non-QM 1.2    vs   Nicholson->Zhang 0.11   Helllock->mortgage 0.0
    ///   Sarah->Jessica 0.14    Nicholson->Lancaster 0.43   Monday->Tuesday 0.43
    /// A consonant-skeleton measure was tried and dropped: it matched Brian->broker, Moropa->mortgage
    /// and "LTV VA"->CLTV in fuzzing, and no required example needs it.
    private static func similarity(heard: [Token], written: [Token]) -> Double {
        let a = lettersOnly(heard), b = lettersOnly(written)
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b || spellsAcronym(heard: heard, written: written) { return 1.2 }
        // A written side that is only the front of the heard side is what a snapshot taken in the
        // middle of typing looks like (Helllock -> "Hel"). And a spelling of the same sound has
        // about the same length: names within 75%, acronyms (which squeeze vowels out:
        // Helllock -> HELOC) within 60%.
        if a.starts(with: b) && a.count - b.count >= 2 { return 0 }
        let isAcronym = written.count == 1 && isAllCaps(written[0].core)
        let coverage = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        if coverage < (isAcronym ? 0.60 : 0.75) { return 0 }
        var prefix = 0
        while prefix < min(4, a.count, b.count) && a[prefix] == b[prefix] { prefix += 1 }
        return editSimilarity(a, b) + 0.05 * Double(prefix)
    }

    /// Best 1-3 word span of `written`, starting at its first word, for the replaced `heard` words.
    private static func bestSpan(heard: [Token], written: [Token]) -> (k: Int, score: Double)? {
        guard !heard.isEmpty, !written.isEmpty else { return nil }
        var best: (k: Int, score: Double)? = nil
        for k in 1...min(maxBlockWords, written.count) {
            let span = Array(written.prefix(k))
            guard isCleanSpan(span) else { continue }
            let s = similarity(heard: heard, written: span)
            if best == nil || s > best!.score + 1e-9 { best = (k, s) }
        }
        return best
    }

    // MARK: - judging one block

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from",
        "as", "is", "are", "was", "were", "be", "been", "am", "it", "its", "this", "that", "these", "those",
        "i", "you", "he", "she", "we", "they", "me", "my", "your", "his", "her", "our", "their", "them",
        "us", "not", "no", "so", "if", "do", "does", "did", "have", "has", "had", "will", "would", "can",
        "could", "should", "what", "who", "how", "when", "where", "there", "here", "than", "then",
        "just", "very", "also",
    ]

    private static let inflections: Set<String> = ["s", "es", "d", "ed", "ing", "ly", "er", "ers"]

    /// HELOC -> HELOCs, Nikolsen -> Nikolsen's: a grammar edit, not a mishearing.
    private static func differsOnlyByEnding(_ a: [Character], _ b: [Character]) -> Bool {
        for (short, long) in [(a, b), (b, a)] where long.count > short.count && long.starts(with: short) {
            if inflections.contains(String(long.dropFirst(short.count))) { return true }
        }
        return false
    }

    private static func evaluate(heard: [Token], written all: [Token], span k: Int, _ sp: Speller) -> Correction? {
        guard (1...maxBlockWords).contains(heard.count), k >= 1, k <= all.count else { return nil }
        let written = Array(all.prefix(k))

        // E-mail / URL anywhere in the block (also in the ignored tail): the user was writing, not fixing.
        for t in heard + all where looksLikeLink(t.raw) { return nil }
        // Digits, symbols, or punctuation between the words of the phrase.
        guard isCleanSpan(heard), isCleanSpan(written) else { return nil }

        let heardText = heard.map { $0.core }.joined(separator: " ")
        let writtenText = written.map { $0.core }.joined(separator: " ")
        if heardText == writtenText { return nil }

        let hKinds = heard.map { kind(of: $0, sp) }
        let wKinds = written.map { kind(of: $0, sp) }
        let hAllEveryday = hKinds.allSatisfy { $0 == .everyday }
        let wAllEveryday = wKinds.allSatisfy { $0 == .everyday }

        if heard.count == 1 && hKinds[0] == .everyday { return nil }     // "may", "will", "grant", "there"
        if hAllEveryday && wAllEveryday { return nil }                    // Monday -> Tuesday, their -> there

        // Shouting is not a term: all-caps is only for acronyms (<= 5 letters, not a real word).
        for (t, kd) in zip(written, wKinds) where isAllCaps(t.core) {
            if kd == .everyday || t.core.filter({ $0.isLetter }).count > maxAcronymLetters { return nil }
        }
        // Words typed in front of the fix ("a HELOC") would be glued onto every future match.
        let writtenStops = written.filter { stopwords.contains($0.key) }.count
        if writtenStops > heard.filter({ stopwords.contains($0.key) }).count { return nil }

        let anyUnknown = hKinds.contains(.unknown) || wKinds.contains(.unknown)
        let writtenIsAcronym = written.count == 1 && isAllCaps(written[0].core)
            && written[0].core.allSatisfy({ $0.isLetter }) && written[0].core.count <= maxAcronymLetters
        var need = lettersOnly(heard).count >= 5 || lettersOnly(written).count >= 5 ? minSimilarity : minSimilarityShort

        if !anyUnknown {
            if hAllEveryday && wKinds.contains(.name) {
                // Fanny May -> Fannie Mae: common words standing in for a name.
            } else if wAllEveryday && hKinds.contains(.name) {
                // Ernest -> earnest. The user must have written the common word in lowercase:
                // a capital (Jon -> John, Smyth -> Smith) means a name was swapped for a name,
                // and at the start of a sentence a capital proves nothing either way.
                if written.contains(where: { $0.core.first?.isUppercase == true }) { return nil }
            } else {
                return nil                                                // name <-> name
            }
            need = max(need, minSimilarityAllKnown)
        } else {
            // A lowercase non-word on the written side is a typo, not a term.
            for (t, kd) in zip(written, wKinds) where kd == .unknown {
                if !t.core.contains(where: { $0.isUppercase }) { return nil }
            }
            // Never turn a heard acronym into something that is not one (HELOC -> hemlock).
            if heard.contains(where: { hasUnknownAcronym($0, sp) }) && !written.contains(where: { hasAllCapsPart($0) }) {
                return nil
            }
        }

        if hAllEveryday {
            // Everyday words rewritten as something else: "the man" -> "Themann", "you are" -> "UAR".
            let stop = heard.filter { stopwords.contains($0.key) }
            if stop.count == heard.count { return nil }
            if !stop.isEmpty && !writtenIsAcronym { return nil }
            if wKinds.contains(.unknown) && !spellsAcronym(heard: heard, written: written) {
                need = max(need, minSimilarityCommonToUnknown)
            }
        }

        if heard.count != written.count { need = max(need, minSimilarityWordCountChange) }

        let hl = lettersOnly(heard), wl = lettersOnly(written)
        if differsOnlyByEnding(hl, wl) { return nil }
        guard similarity(heard: heard, written: written) >= need else { return nil }
        return Correction(heard: heardText, written: writtenText)
    }

    /// One matched word whose spelling differs only by case: heloc -> HELOC.
    private static func caseOnly(heard: Token, written: Token, _ sp: Speller) -> Correction? {
        guard heard.core != written.core else { return nil }
        guard !looksLikeLink(heard.raw), !looksLikeLink(written.raw) else { return nil }
        guard isPlainWord(heard.core), isPlainWord(written.core) else { return nil }
        // The recognizer's form must not be a real word (the -> The, Sarah -> SARAH never).
        guard kind(of: heard, sp) == .unknown else { return nil }
        // The fix must add capitals, and be shaped like a term, not like shouting.
        let hUp = heard.core.filter { $0.isUppercase }.count
        let wUp = written.core.filter { $0.isUppercase }.count
        guard wUp > hUp else { return nil }
        if isAllCaps(written.core) {
            guard written.core.filter({ $0.isLetter }).count <= maxAcronymLetters else { return nil }
        }
        // Only the first letter capitalized: grammar at the start of a sentence (never learn), and
        // elsewhere only for a proper noun the checker knows (sarah -> Sarah). "heloc" -> "Heloc"
        // is nobody's spelling, and the rule would also rewrite every HELOC.
        let wLetters = written.core.filter { $0.isLetter }
        let firstOnly = wUp == 1 && written.core.first?.isUppercase == true && wLetters.count > 1
        if firstOnly {
            if written.sentenceStart { return nil }
            if kind(of: written, sp) != .name { return nil }
        }
        return Correction(heard: heard.core, written: written.core)
    }
}
