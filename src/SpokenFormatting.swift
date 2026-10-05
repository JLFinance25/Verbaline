import Foundation

/// Spoken layout commands: "new line", "new paragraph", "bullet point".
///
/// To avoid firing on ordinary speech ("a new line of loans", "the bullet point is…"), a command
/// is ignored when the word before it is a determiner or possessive, or when "of" follows it.
enum SpokenFormatting {
    private enum Command { case line, paragraph, bullet }

    private static let commandRX = try! NSRegularExpression(pattern:
        "[ \\t]*(?<![\\p{L}\\p{N}])(new ?line|new paragraph|next paragraph|bullet point|next bullet)(?![\\p{L}\\p{N}])[.,;:!?]*[ \\t]*",
        options: .caseInsensitive)

    private static let blockingWordsBefore: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "our", "their", "his", "her", "its",
        "one", "another", "each", "every", "any", "some", "no", "first", "last", "whole", "entire"]

    /// True if the text contains at least one real formatting command.
    static func containsCommand(_ text: String) -> Bool {
        let ns = text as NSString
        return commandRX.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .contains { isRealCommand($0, in: ns) }
    }

    static func apply(_ text: String) -> String {
        let ns = text as NSString
        let matches = commandRX.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { isRealCommand($0, in: ns) }
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = 0
        for m in matches {
            var before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let command = kind(ns.substring(with: m.range(at: 1)))
            if command == .bullet {
                // "pay stubs, bullet point bank statements" → no dangling comma at the end of a bullet line
                while let last = before.last, last == "," || last == " " { before.removeLast() }
            }
            out += before
            switch command {
            case .line: out += "\n"
            case .paragraph: out += "\n\n"
            case .bullet: out += out.isEmpty ? "• " : "\n• "
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return capitalizeAfterBreaks(out)
    }

    // MARK: - Helpers

    private static func kind(_ phrase: String) -> Command {
        let p = phrase.lowercased()
        if p.contains("paragraph") { return .paragraph }
        if p.contains("bullet") { return .bullet }
        return .line
    }

    private static func isRealCommand(_ match: NSTextCheckingResult, in ns: NSString) -> Bool {
        let phraseRange = match.range(at: 1)
        // Word right before the phrase (skipping spaces, not punctuation: "Sarah, new line" is still a command).
        let before = ns.substring(to: phraseRange.location)
        let prevWord = before.reversed().drop(while: { $0 == " " || $0 == "\t" })
            .prefix(while: { $0.isLetter || $0 == "'" }).reversed()
        if blockingWordsBefore.contains(String(prevWord).lowercased()) { return false }
        // "new line of credit"
        let after = ns.substring(from: phraseRange.location + phraseRange.length)
        let nextWord = after.drop(while: { $0 == " " }).prefix(while: { $0.isLetter }).lowercased()
        if nextWord == "of" { return false }
        return true
    }

    /// Capitalize the first letter of every new line and bullet.
    private static func capitalizeAfterBreaks(_ s: String) -> String {
        var chars = Array(s)
        var atLineStart = true
        for i in chars.indices {
            let c = chars[i]
            if c == "\n" { atLineStart = true; continue }
            if atLineStart {
                if c == " " || c == "•" { continue }
                if c.isLowercase { chars[i] = Character(c.uppercased()) }
                atLineStart = false
            }
        }
        return String(chars)
    }
}
