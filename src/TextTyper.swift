import Cocoa

/// "Type it out": inserts dictated text as keystrokes, one character at a time, instead of pasting.
/// Works in apps that block pasting and never touches the clipboard. Line breaks are typed as
/// Shift+Return so chat apps (Claude, Slack, Messages) don't send the message early.
///
/// Used for the user's own dictated words only — Command Mode's AI-written text always pastes.
final class TextTyper {
    enum Speed: String, CaseIterable {
        case fast, steady
        /// Pause between keystrokes.
        var delay: TimeInterval { self == .fast ? 0.006 : 0.04 }
        var label: String { self == .fast ? "Fast" : "Steady" }
    }

    enum Stroke: Equatable {
        case text(String)   // one character (a whole grapheme, so emoji and accents stay intact)
        case lineBreak
    }

    private let queue = DispatchQueue(label: "Verbaline.typer", qos: .userInitiated)
    private let lock = NSLock()
    private var _cancelled = false
    private var _typing = false

    var isTyping: Bool { lock.withLock { _typing } }

    /// Stop typing after the current keystroke (Esc).
    func cancel() { lock.withLock { _cancelled = true } }

    /// The keystrokes for `text`. Pure — used by the tests.
    static func strokes(for text: String) -> [Stroke] {
        text.replacingOccurrences(of: "\r\n", with: "\n").map { c in
            c == "\n" || c == "\r" ? .lineBreak : .text(String(c))
        }
    }

    /// Types `text` into the frontmost app. `post` is replaceable so tests never send real keystrokes
    /// to whatever app is in front. Calls back on the main thread with whether it finished (vs. Esc).
    func type(_ text: String, speed: Speed, post: ((Stroke) -> Void)? = nil,
              completion: @escaping (_ finished: Bool) -> Void) {
        let strokes = Self.strokes(for: text)
        let send = post ?? Self.postToFrontmost
        lock.withLock { _cancelled = false; _typing = true }
        queue.async { [self] in
            var finished = true
            for stroke in strokes {
                if lock.withLock({ _cancelled }) { finished = false; break }
                send(stroke)
                Thread.sleep(forTimeInterval: speed.delay)
            }
            lock.withLock { _typing = false }
            DispatchQueue.main.async { completion(finished) }
        }
    }

    // MARK: - Keystrokes

    /// Posts at the HID level, like a real keyboard, so every app sees ordinary typing.
    static func postToFrontmost(_ stroke: Stroke) {
        for event in events(for: stroke) { event.post(tap: .cghidEventTap) }
    }

    /// Posts to one process (tests use this to type into their own window without stealing focus).
    static func post(_ stroke: Stroke, toPid pid: pid_t) {
        for event in events(for: stroke) { event.postToPid(pid) }
    }

    private static func events(for stroke: Stroke) -> [CGEvent] {
        let source = CGEventSource(stateID: .hidSystemState)
        switch stroke {
        case .text(let s):
            let units = Array(s.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return [] }
            for e in [down, up] {
                e.flags = []   // never inherit a held modifier (that would turn letters into shortcuts)
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            return [down, up]
        case .lineBreak:
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else { return [] }
            down.flags = .maskShift
            up.flags = .maskShift
            return [down, up]
        }
    }
}
