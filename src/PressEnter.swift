import Foundation

/// "press enter" / "press return" as the last words of a dictation: paste the rest, then press Return
/// (which sends the message in chat apps).
///
/// Only the very end counts ("press enter to log in, then…" is just text), and not right after a word
/// that makes it a description rather than a command ("tell them to press enter", "you press enter").
/// A sentence break in between undoes that: "Ask them to. Press enter." still sends.
enum PressEnter {
    private static let tailRX = try! NSRegularExpression(pattern:
        "(?<![\\p{L}\\p{N}])press[ ,]+(?:enter|return)[\\s.,;:!?]*$", options: .caseInsensitive)

    private static let blockingWordsBefore: Set<String> = [
        "to", "you", "we", "they", "i", "he", "she", "it", "should", "can", "could", "will", "would", "must",
        "then", "and", "or", "just", "not", "don't", "dont", "never", "always", "please"]

    /// Splits off a trailing "press enter". `text` is what's left to paste (empty: press Return only).
    static func split(_ raw: String) -> (text: String, pressEnter: Bool) {
        let ns = raw as NSString
        guard let m = tailRX.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else {
            return (raw, false)
        }
        let before = ns.substring(to: m.range.location)
        if let word = lastWord(before), blockingWordsBefore.contains(word) { return (raw, false) }
        var text = before
        // "Sounds good, press enter" → "Sounds good" (no dangling comma); keep . ! ?
        while let last = text.last, last.isWhitespace || last == "," || last == ";" || last == ":" { text.removeLast() }
        return (text, true)
    }

    /// The word right before the command, lowercased — nil if a sentence break (. ! ?) comes first.
    private static func lastWord(_ text: String) -> String? {
        var word = ""
        for ch in text.reversed() {
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
}
