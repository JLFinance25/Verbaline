import Cocoa
import ApplicationServices

/// Finding and reading text boxes in other apps through Accessibility.
///
/// Two macOS quirks shape this:
/// - Asking the *system-wide* element for the focused UI element fails here with kAXErrorCannotComplete,
///   so every query goes to a specific app's element instead.
/// - Electron/Chromium apps (Claude, Slack, Chrome…) only build their accessibility tree when asked, via
///   "AXManualAccessibility", and often don't report a focused element even then — so a text box can
///   also be found by searching the window for the one that contains the text we just pasted.
enum AXText {
    private static let lock = NSLock()
    private static var enabledPids = Set<pid_t>()
    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    /// The app's accessibility element, with its full tree switched on (once per process).
    static func app(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        let first = lock.withLock { enabledPids.insert(pid).inserted }
        if first {
            // Harmless no-op for native apps (they return an "unsupported attribute" error).
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return app
    }

    static func focusedElement(in pid: pid_t) -> AXUIElement? {
        element(app(pid), kAXFocusedUIElementAttribute)
    }

    /// The text box in `pid`'s front window whose text contains `text` — the focused one if it qualifies.
    static func textElement(containing text: String, in pid: pid_t, maxNodes: Int = 3000) -> AXUIElement? {
        let appElement = app(pid)
        if let focused = element(appElement, kAXFocusedUIElementAttribute), !isSecure(focused),
           let value = string(focused, kAXValueAttribute), value.contains(text) {
            return focused
        }
        // Search the focused window first, then the app's other windows.
        var windows: [AXUIElement] = []
        if let w = element(appElement, kAXFocusedWindowAttribute) ?? element(appElement, kAXMainWindowAttribute) { windows.append(w) }
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
           let all = ref as? [AXUIElement] {
            windows += all.filter { w in !windows.contains { CFEqual($0, w) } }
        }
        guard !windows.isEmpty else { return nil }
        var queue = windows
        var visited = 0
        var fallback: AXUIElement?
        while !queue.isEmpty, visited < maxNodes {
            let el = queue.removeFirst()
            visited += 1
            let role = string(el, kAXRoleAttribute) ?? ""
            if textRoles.contains(role) || role == "AXWebArea" || role == "AXGroup" {
                if !isSecure(el), let value = string(el, kAXValueAttribute), value.contains(text) {
                    if textRoles.contains(role) { return el }
                    fallback = fallback ?? el   // an editable web area/group can hold the text too
                }
            }
            var kidsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
               let kids = kidsRef as? [AXUIElement] {
                queue.append(contentsOf: kids)
            }
        }
        return fallback
    }

    enum Selection { case text(String), nothingSelected, unknown }

    /// The selected text in the app's focused element, if the app shares it. `.unknown` when the app
    /// doesn't say (Electron apps like Claude) — the caller can fall back to copying.
    static func selection(in pid: pid_t) -> Selection {
        guard let el = focusedElement(in: pid) else { return .unknown }
        if isSecure(el) { return .nothingSelected }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &ref) == .success,
              let text = ref as? String else { return .unknown }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothingSelected : .text(text)
    }

    static func isSecure(_ el: AXUIElement) -> Bool {
        string(el, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
            || string(el, kAXRoleAttribute) == "AXSecureTextField"
    }

    static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    static func cursor(of el: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    static func appName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
    }

    private static func element(_ el: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }
}
