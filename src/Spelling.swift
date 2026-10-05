import Foundation

/// "spell" followed by letters: the letters become one word. "email spell K E R G E R" → "email Kerger".
///
/// The recognizer writes spelled letters several ways: "H E L O C", "H E-L-O-C", "H, E, L, O, C",
/// "K-ER-G-ER", or already joined ("WYQUR"). All count. "age"/"aitch" right after "spell" is the letter H.
/// Five letters or fewer come out in capitals (HELOC, NMLS); six or more get a capital first letter (Kerger).
///
/// Left alone: fewer than two letters ("can you spell that", "spell a word"), and "spell" after a word that
/// makes it ordinary speech ("how do you spell", "a dry spell").
///
/// Spelled words are then shielded with placeholders so the dictionary and formatting can't change them.
enum Spelling {
    // A spelled piece: one letter, possibly hyphen-joined to more ("E-L-O-C", "K-ER-G-ER"),
    // or letters the recognizer already ran together in capitals ("MLS", "WYQUR").
    private static let piece = "(?:[A-Za-z](?:-[A-Z]{1,3}|-[a-z])*|[A-Z]{2,8}(?:-[A-Z]{1,3})*)(?![\\p{L}\\p{N}'’])"
    // Between pieces: spaces/commas, or a period when another single letter follows ("H. E. L.").
    private static let gap = "(?:[ ,]+|\\.[ ]+(?=[A-Za-z](?![\\p{L}\\p{N}'’])))"
    private static let runRX = try! NSRegularExpression(pattern:
        "(?<![\\p{L}\\p{N}])(?i:spell)[,:]?[ ]+(?:((?i:age|aitch))[ ,.]+)?(\(piece)(?:\(gap)\(piece))*)")

    private static let blockingWordsBefore: Set<String> = [
        "you", "can", "can't", "cannot", "could", "how", "i", "we", "they", "he", "she", "not", "never",
        "will", "would", "should", "please", "a", "an", "the", "this", "that", "my", "your", "our",
        "his", "her", "their", "dry", "cold", "magic", "long", "short"]

    static func containsSpelling(_ text: String) -> Bool { !runs(in: text).isEmpty }

    /// Replaces each "spell …" with the spelled word. Returns the new text and the words, in order.
    static func apply(_ text: String) -> (text: String, words: [String]) {
        let found = runs(in: text)
        guard !found.isEmpty else { return (text, []) }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for (range, word) in found {
            out += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            out += word
            cursor = range.location + range.length
        }
        out += ns.substring(from: cursor)
        return (out, found.map(\.word))
    }

    // MARK: - Shielding

    // Private-use characters (no letters or digits), separate from the snippet placeholders (E000/E001, E100+).
    private static let open = Unicode.Scalar(0xE002)!
    private static let close = Unicode.Scalar(0xE003)!
    private static let maxPerDictation = 255

    /// Swaps each spelled word (whole-word, first match after the previous one) for a placeholder.
    static func shield(_ text: String, _ words: [String]) -> (text: String, words: [String]) {
        guard !words.isEmpty else { return (text, []) }
        var out = text
        var shielded: [String] = []
        var searchFrom = out.startIndex
        for word in words.prefix(maxPerDictation) {
            guard let range = wholeWord(word, in: out, from: searchFrom) else { continue }
            var placeholder = String.UnicodeScalarView()
            placeholder.append(open)
            placeholder.append(Unicode.Scalar(0xE200 + UInt32(shielded.count))!)
            placeholder.append(close)
            let tag = String(placeholder)
            let offset = out.distance(from: out.startIndex, to: range.lowerBound)
            out.replaceSubrange(range, with: tag)
            searchFrom = out.index(out.startIndex, offsetBy: offset + tag.count)
            shielded.append(word)
        }
        return (out, shielded)
    }

    /// Puts the spelled words back where `shield` left placeholders.
    static func unshield(_ text: String, _ words: [String]) -> String {
        guard !words.isEmpty else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == open, i + 2 < scalars.count, scalars[i + 2] == close {
                let n = Int(scalars[i + 1].value) - 0xE200
                if n >= 0, n < words.count {
                    out.append(contentsOf: words[n].unicodeScalars)
                    i += 3
                    continue
                }
            }
            out.append(scalars[i])
            i += 1
        }
        return String(out)
    }

    // MARK: - Helpers

    private static func runs(in text: String) -> [(range: NSRange, word: String)] {
        let ns = text as NSString
        return runRX.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var letters = ns.substring(with: m.range(at: 2)).filter { $0.isLetter }
            if m.range(at: 1).location != NSNotFound { letters = "H" + letters }
            guard letters.count >= 2,
                  !blockingWordsBefore.contains(wordBefore(m.range.location, in: ns) ?? "") else { return nil }
            let upper = letters.uppercased()
            let word = upper.count <= 5 ? upper : upper.prefix(1) + upper.dropFirst().lowercased()
            return (m.range, word)
        }
    }

    /// The word right before `location`, lowercased; nil if a sentence break (. ! ? new line) comes first.
    private static func wordBefore(_ location: Int, in ns: NSString) -> String? {
        let before = ns.substring(to: location)
        var word = ""
        for ch in before.reversed() {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" {
                word.append(ch)
            } else if !word.isEmpty {
                break
            } else if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                return nil
            }
        }
        return word.isEmpty ? nil : String(word.reversed()).lowercased().replacingOccurrences(of: "’", with: "'")
    }

    private static func wholeWord(_ word: String, in text: String, from start: String.Index) -> Range<String.Index>? {
        var from = start
        while let r = text.range(of: word, range: from..<text.endIndex) {
            let beforeOK = r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isLetter
            let afterOK = r.upperBound == text.endIndex || !text[r.upperBound].isLetter
            if beforeOK && afterOK { return r }
            from = r.upperBound
        }
        return nil
    }
}
