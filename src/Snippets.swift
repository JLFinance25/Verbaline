import Foundation

/// Saved text you can paste by voice: say the trigger phrase and the exact saved text goes in its place.
///
/// File format (~/Library/Application Support/Verbaline/snippets.txt):
///     [insert my signature]
///     Alex Example
///     Loan Officer · NMLS #000000
/// A line in [brackets] starts a snippet; the lines under it are its text. Lines starting with "# " are notes.
///
/// Expansions are swapped in as placeholders before the dictionary and formatting run, then filled in
/// at the very end — so nothing else can alter them.
final class Snippets {
    let fileURL: URL

    private struct Entry {
        let trigger: String
        let text: String
        let regex: NSRegularExpression
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var loadedModDate: Date?

    // Private-use characters (no letters or digits), so no other step touches a placeholder.
    // Placeholder n is: open, U+E100+n, close.
    private static let open: Character = "\u{E000}"
    private static let close: Character = "\u{E001}"
    private static let maxPerDictation = 255

    init(fileURL: URL) {
        self.fileURL = fileURL
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? Self.seedText.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        reloadIfChanged()
    }

    var triggers: [String] { reloadIfChanged(); return lock.withLock { entries.map(\.trigger) } }

    func containsTrigger(_ text: String) -> Bool {
        !matches(in: text).isEmpty
    }

    /// Replaces triggers with placeholders. Returns the marked text and what each placeholder stands for.
    func mark(_ text: String) -> (text: String, expansions: [String]) {
        let found = matches(in: text)
        guard !found.isEmpty else { return (text, []) }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        var expansions: [String] = []
        for (range, expansion) in found.prefix(Self.maxPerDictation) {
            out += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            out.append(Self.open)
            out.unicodeScalars.append(Unicode.Scalar(0xE100 + UInt32(expansions.count))!)
            out.append(Self.close)
            expansions.append(expansion)
            cursor = range.location + range.length
        }
        out += ns.substring(from: cursor)
        return (out, expansions)
    }

    /// Puts the saved text back where `mark` left placeholders.
    func fill(_ text: String, _ expansions: [String]) -> String {
        guard !expansions.isEmpty else { return text }
        let open = Self.open.unicodeScalars.first!, close = Self.close.unicodeScalars.first!
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == open, i + 2 < scalars.count, scalars[i + 2] == close {
                let n = Int(scalars[i + 1].value) - 0xE100
                if expansions.indices.contains(n) {
                    out.append(contentsOf: expansions[n].unicodeScalars)
                    i += 3
                    continue
                }
            }
            out.append(scalars[i])
            i += 1
        }
        return String(out)
    }

    // MARK: - Matching

    /// Non-overlapping trigger matches in order; the longer trigger wins when two overlap.
    private func matches(in text: String) -> [(NSRange, String)] {
        reloadIfChanged()
        let current = lock.withLock { entries }
        guard !current.isEmpty, !text.isEmpty else { return [] }
        let full = NSRange(location: 0, length: (text as NSString).length)
        var all: [(NSRange, String, Int)] = []
        for e in current {
            for m in e.regex.matches(in: text, range: full) { all.append((m.range, e.text, e.trigger.count)) }
        }
        all.sort { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0.location < $1.0.location }
        var chosen: [(NSRange, String)] = []
        for candidate in all where !chosen.contains(where: { NSIntersectionRange($0.0, candidate.0).length > 0 }) {
            chosen.append((candidate.0, candidate.1))
        }
        return chosen.sorted { $0.0.location < $1.0.location }
    }

    /// Whole words, any case, any punctuation between words ("Insert my signature." matches
    /// "insert my signature"); punctuation right after the trigger is swallowed with it. Inside a word the
    /// recognizer may add a space, dot or hyphen ("NMLS" → "N.M.L.S.", "verbaline" → "my flow"), so those are allowed too.
    private static func regex(for trigger: String) -> NSRegularExpression? {
        let words = trigger.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return nil }
        let body = words
            .map { word in word.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s.\\-]?") }
            .joined(separator: "[\\s,.;:!?\\-]*")
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(body)(?![\\p{L}\\p{N}])[.,;:!?]*",
                                        options: .caseInsensitive)
    }

    // MARK: - File

    private func reloadIfChanged() {
        let mod = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        if lock.withLock({ mod == loadedModDate }) { return }
        guard let data = try? Data(contentsOf: fileURL), let contents = String(data: data, encoding: .utf8) else { return }
        let parsed = Self.parse(contents)
        lock.withLock {
            entries = parsed
            loadedModDate = mod
        }
    }

    static func parseForTesting(_ contents: String) -> [(trigger: String, text: String)] {
        parse(contents).map { ($0.trigger, $0.text) }
    }

    private static func parse(_ contents: String) -> [Entry] {
        var result: [Entry] = []
        var trigger: String?
        var body: [String] = []
        func flush() {
            guard let t = trigger else { return }
            while let last = body.last, last.trimmingCharacters(in: .whitespaces).isEmpty { body.removeLast() }
            let text = body.joined(separator: "\n")
            if !text.isEmpty, let rx = regex(for: t) { result.append(Entry(trigger: t, text: text, regex: rx)) }
        }
        for rawLine in contents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "#" || line.hasPrefix("# ") { continue }
            if line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 {
                flush()
                trigger = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                body = []
            } else if trigger != nil {
                if body.isEmpty && line.isEmpty { continue }   // blank line right after the trigger
                body.append(rawLine)
            }
        }
        flush()
        return result
    }

    static let seedText = """
    # Verbaline snippets
    #
    # Say a trigger phrase while dictating and Verbaline pastes the exact text saved under it.
    # Snippets are never changed by the AI cleanup or the dictionary, so they're safe for
    # disclaimers, NMLS numbers, links and signatures.
    #
    # To add one, write the phrase in [brackets], then the exact text on the lines below:
    #
    #   [insert my signature]
    #   Your Name
    #   Loan Officer · NMLS #000000
    #
    # Tips:
    # - Pick phrases you'd never say by accident ("insert my signature", not "signature").
    # - Say "new line my signature" if you want it on its own line.
    # - Lines starting with "# " are notes and are ignored.

    [insert test snippet]
    This text came from a Verbaline snippet. Open the Verbaline menu → Edit Snippets… to add your own.

    """
}
