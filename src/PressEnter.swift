import Foundation

/// "press enter" / "press return" said on its own, as a whole dictation: press Return (which sends the
/// message in chat apps). The user has already seen the text on screen, so nothing is sent unchecked.
///
/// Said at the end of a longer dictation it's just text ("sounds good, press enter" pastes as is):
/// Verbaline never pastes and sends in one step, so a misheard word can't go out by itself.
enum PressEnter {
    private static let wholeRX = try! NSRegularExpression(pattern:
        "^[\\s.,;:!?]*press[ ,]+(?:enter|return)[\\s.,;:!?]*$", options: .caseInsensitive)

    /// `pressEnter` is true only when the whole dictation is the command; then `text` is empty.
    static func split(_ raw: String) -> (text: String, pressEnter: Bool) {
        let range = NSRange(location: 0, length: (raw as NSString).length)
        return wholeRX.firstMatch(in: raw, range: range) == nil ? (raw, false) : ("", true)
    }
}
