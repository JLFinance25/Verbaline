import Cocoa
import ApplicationServices

/// Types text into whatever app has focus: put it on the clipboard, press ⌘V, then put the
/// user's previous clipboard back. Needs Accessibility permission to post the keystroke. Main thread only.
enum TextInserter {
    /// Clipboard contents as items of (type, data), in their original order.
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    /// While one of our pastes is still on the clipboard, this holds the user's real clipboard, so a second
    /// paste right after (⌃⌘V just after a dictation) restores the user's content — not our previous paste.
    private static var pendingOriginal: Snapshot?
    private static var ourChangeCount: Int?
    private static var restoreWork: DispatchWorkItem?

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Pastes `text` into the focused app. Returns false if it couldn't (no Accessibility permission) —
    /// the text is then left on the clipboard so it isn't lost.
    /// `smartSpace`: add a space when the cursor sits right after a word. Off when replacing a selection.
    @discardableResult
    static func insert(_ text: String, smartSpace: Bool = true) -> Bool {
        guard AXIsProcessTrusted() else {
            copyToClipboard(text)
            return false
        }
        let toPaste = smartSpace && needsLeadingSpace() ? " " + text : text
        paste(toPaste, into: .general, press: pressCommandV)
        return true
    }

    /// True when the focused field in the frontmost app is a password field.
    static func focusedFieldIsSecure() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let element = AXText.focusedElement(in: pid) else { return false }
        return AXText.isSecure(element)
    }

    /// " " when the cursor sits right after a word in the frontmost app, else "". (Used by typing mode.)
    static func leadingSpaceIfNeeded() -> String { needsLeadingSpace() ? " " : "" }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// The clipboard swap, kept apart from the keystroke so it can be tested on a private pasteboard.
    static func paste(_ text: String, into pb: NSPasteboard, press: () -> Void, restoreAfter delay: Double = 0.6) {
        let original: Snapshot
        if let pending = pendingOriginal, pb.changeCount == ourChangeCount {
            original = pending          // our last paste is still there; the user's content is the one saved then
        } else {
            original = snapshot(pb)
        }
        restoreWork?.cancel()

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Tells clipboard managers (Raycast, Paste, etc.) not to record this.
        pb.setString("", forType: transientType)
        let changeCount = pb.changeCount
        pendingOriginal = original
        ourChangeCount = changeCount

        press()

        let work = DispatchWorkItem {
            // If something else touched the clipboard meanwhile, leave it alone.
            if pb.changeCount == changeCount { restore(original, to: pb) }
            pendingOriginal = nil
            ourChangeCount = nil
            restoreWork = nil
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Copies the frontmost app's selection with ⌘C and hands it back, then restores the user's clipboard.
    /// Calls back with nil if nothing was copied (nothing selected). Main thread.
    static func copySelection(completion: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted() else { completion(nil); return }
        let pb = NSPasteboard.general
        // Same rule as paste(): if our last paste is still on the clipboard, the user's content is the saved one.
        let original: Snapshot
        if let pending = pendingOriginal, pb.changeCount == ourChangeCount { original = pending } else { original = snapshot(pb) }
        restoreWork?.cancel()
        pendingOriginal = nil
        ourChangeCount = nil
        restoreWork = nil

        let started = Date()
        func waitForControlRelease() {
            // Still holding Control from fn+Control? ⌘C would arrive as ⌃⌘C. Wait briefly for the key-up.
            if CGEventSource.flagsState(.combinedSessionState).contains(.maskControl),
               Date().timeIntervalSince(started) < 0.6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: waitForControlRelease)
                return
            }
            let before = pb.changeCount
            pressKey(8, flags: .maskCommand)   // C
            let copyStarted = Date()
            func check() {
                if pb.changeCount != before {
                    let text = pb.string(forType: .string)
                    restore(original, to: pb)
                    completion(text)
                } else if Date().timeIntervalSince(copyStarted) > 0.5 {
                    completion(nil)   // the copy didn't change anything: nothing selected; clipboard untouched
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: check)
                }
            }
            check()
        }
        waitForControlRelease()
    }

    // MARK: - Clipboard save/restore

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ saved: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    // MARK: - Keystroke

    private static func pressCommandV() { pressKey(9, flags: .maskCommand) }   // V

    private static func pressKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Smart spacing

    /// Caps every Accessibility query this process makes, so a frozen app can't stall Verbaline
    /// (the system default is several seconds). Setting it on the system-wide element applies globally.
    private static let axTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
    }()

    /// True when the character right before the cursor is a non-space, so "Hi.|" + "How are you"
    /// becomes "Hi. How are you". Uses Accessibility; quietly returns false where apps don't support it.
    private static func needsLeadingSpace() -> Bool {
        _ = axTimeout
        // Ask the frontmost app directly: the system-wide focused-element query fails on this macOS.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let element = AXText.focusedElement(in: pid), !AXText.isSecure(element) else { return false }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return false }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.location > 0 else { return false }

        var prev = CFRange(location: range.location - 1, length: 1)
        guard let prevValue = AXValueCreate(.cfRange, &prev) else { return false }
        var strRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         prevValue, &strRef) == .success,
              let s = strRef as? String, let c = s.last else { return false }
        // No space after whitespace or an opening bracket/quote: "(" + "see attached" → "(see attached".
        return !c.isWhitespace && !"([{“‘«".contains(c)
    }
}
