import Cocoa
import ApplicationServices

/// After a paste, watches the text box for about a minute so we can see how the user fixed the text.
///
/// It finds the text box (in the app that received the paste) that now contains the pasted text,
/// reads only that box through Accessibility (the permission Verbaline already has for pasting), skips
/// password fields, keeps nothing but the pasted region, and reports (pasted, edited) once the user
/// starts another dictation, the box goes away, or the minute is up — only after the text has settled.
final class EditWatcher {
    /// Called on the main thread when a watch ends with the region changed.
    var onEdited: ((_ pasted: String, _ edited: String) -> Void)?
    /// Called on the main thread with what happened on the last watch, e.g. "Claude: watching" — for status.json.
    var onStatus: ((String) -> Void)?

    private let queue = DispatchQueue(label: "Verbaline.editWatcher", qos: .utility)
    private var generation = 0                  // bumped by watch()/finishNow(); only touched on `queue`
    private let watchSeconds = 60.0
    private let pollSeconds = 1.0
    private let maxFieldLength = 200_000        // don't poll huge documents
    private let settleSeconds = 3.0
    private let maxExtraSeconds = 30.0

    /// Start watching right after `pasted` (without any leading space we added) was pasted into app `pid`.
    /// Ends any watch already running, reporting its result first.
    func watch(pasted: String, in pid: pid_t) {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, pid > 0 else { return }
        queue.async { [self] in
            generation += 1
            let mine = generation
            // Give the target app a moment to apply the ⌘V before taking the baseline.
            queue.asyncAfter(deadline: .now() + 0.6) { [self] in self.begin(text, pid: pid, generation: mine, attempt: 0) }
        }
    }

    /// End the current watch now (e.g. a new dictation is starting) and report what we saw.
    func finishNow() {
        queue.async { [self] in generation += 1 }
    }

    // MARK: - Polling (on `queue`)

    private struct Session {
        let pasted: String
        let element: AXUIElement
        let pid: pid_t
        let before: String       // text just before the pasted region at paste time
        let after: String        // text just after it
        let start: Int           // where the region started (UTF-16 offset), to pick the right anchor match
        var lastRegion: String
        let deadline: Date
        var lastChange = Date()  // when the region last changed; we only learn from text that has settled
    }

    private func report(_ status: String, _ pid: pid_t) {
        let line = "\(AXText.appName(pid)): \(status)"
        DispatchQueue.main.async { [weak self] in self?.onStatus?(line) }
    }

    private func begin(_ pasted: String, pid: pid_t, generation mine: Int, attempt: Int) {
        guard mine == generation else { return }
        guard let element = AXText.textElement(containing: pasted, in: pid) else {
            // Electron apps build their accessibility tree on first request — give it one more moment.
            if attempt == 0 {
                queue.asyncAfter(deadline: .now() + 0.8) { [self] in self.begin(pasted, pid: pid, generation: mine, attempt: 1) }
                return
            }
            return report("couldn't find the pasted text in a readable text box", pid)
        }
        guard let value = AXText.string(element, kAXValueAttribute) else { return report("text box isn't readable", pid) }
        guard value.utf16.count <= maxFieldLength else { return report("text box too large to watch", pid) }
        guard let found = Self.locatePaste(pasted, in: value, cursor: AXText.cursor(of: element)) else {
            return report("pasted text not found in the box (the app reformats it)", pid)
        }
        report("watching for fixes", pid)
        let session = Session(pasted: pasted, element: element, pid: pid, before: found.before, after: found.after,
                              start: found.start, lastRegion: pasted, deadline: Date().addingTimeInterval(watchSeconds))
        queue.asyncAfter(deadline: .now() + pollSeconds) { [self] in self.poll(session, generation: mine) }
    }

    private func poll(_ s: Session, generation mine: Int) {
        var session = s
        let superseded = mine != generation   // a new dictation or paste: the user is done here
        // At the minute mark, keep going a little longer if they're mid-edit, so a half-typed fix isn't learned.
        let settled = Date().timeIntervalSince(session.lastChange) >= settleSeconds
        let pastDeadline = Date() >= session.deadline
        let hardStop = Date() >= session.deadline.addingTimeInterval(maxExtraSeconds)
        let stillWatching = !superseded && (!pastDeadline || (!settled && !hardStop))
        // If the box is gone (closed, or the message was sent), use what we last saw.
        if let value = AXText.string(session.element, kAXValueAttribute), value.utf16.count <= maxFieldLength {
            if let region = Self.region(in: value, before: session.before, after: session.after, near: session.start) {
                if region != session.lastRegion { session.lastChange = Date() }
                session.lastRegion = region
            } else {
                report("stopped: the text around it changed", session.pid)
                return finish(session)   // surroundings changed too much to tell what's ours (or the box was cleared)
            }
            if stillWatching {
                queue.asyncAfter(deadline: .now() + pollSeconds) { [self] in self.poll(session, generation: mine) }
                return
            }
        }
        finish(session)
    }

    private func finish(_ s: Session) {
        report(s.lastRegion == s.pasted ? "done: no fixes made" : "done: saw a fix", s.pid)
        guard s.lastRegion != s.pasted else { return }
        // Still mid-edit when the watch ended: don't risk learning a half-typed word.
        guard Date().timeIntervalSince(s.lastChange) >= 1.0 else {
            return report("done: still being edited, skipped", s.pid)
        }
        let pasted = s.pasted, edited = s.lastRegion
        DispatchQueue.main.async { [weak self] in self?.onEdited?(pasted, edited) }
    }

    // MARK: - Locating the pasted text (pure, testable)

    /// Finds the pasted text in the field right after pasting. Prefers the occurrence ending at the cursor.
    /// Returns the text around it (up to 40 characters each side) as anchors for later polls.
    static func locatePaste(_ pasted: String, in value: String, cursor: Int?) -> (before: String, after: String, start: Int)? {
        let ns = value as NSString
        let p = pasted as NSString
        var range: NSRange?
        if let cursor, cursor >= p.length, cursor <= ns.length {
            let candidate = NSRange(location: cursor - p.length, length: p.length)
            if ns.substring(with: candidate) == pasted { range = candidate }
        }
        if range == nil {
            let r = ns.range(of: pasted, options: .backwards)
            if r.location != NSNotFound { range = r }
        }
        guard let r = range else { return nil }
        let beforeStart = max(0, r.location - 40)
        let afterEnd = min(ns.length, r.location + r.length + 40)
        return (ns.substring(with: NSRange(location: beforeStart, length: r.location - beforeStart)),
                ns.substring(with: NSRange(location: r.location + r.length, length: afterEnd - (r.location + r.length))),
                r.location)
    }

    /// The current text between the two anchors, using the `before` match nearest the original position.
    static func region(in value: String, before: String, after: String, near start: Int) -> String? {
        let ns = value as NSString
        var regionStart = 0
        if !before.isEmpty {
            var best: Int?
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let r = ns.range(of: before, options: [], range: search)
                if r.location == NSNotFound { break }
                let end = r.location + r.length
                if best == nil || abs(end - start) < abs(best! - start) { best = end }
                search = NSRange(location: r.location + 1, length: ns.length - r.location - 1)
            }
            guard let b = best else { return nil }
            regionStart = b
        }
        var regionEnd = ns.length
        if !after.isEmpty {
            let r = ns.range(of: after, options: [], range: NSRange(location: regionStart, length: ns.length - regionStart))
            guard r.location != NSNotFound else { return nil }
            regionEnd = r.location
        }
        return ns.substring(with: NSRange(location: regionStart, length: regionEnd - regionStart))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
