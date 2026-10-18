import Foundation

// AppStyles
// ---------
// Writing style per kind of app, like Wispr Flow's "Styles": formal in email, casual in chats and texts.
// Pure formatting rules, no AI: a style only changes capital letters, the final period and (formal email)
// puts a greeting on its own line. It never changes, adds or drops a word or a number.
//
//     AppStyles.category(bundleID:windowTitle:) -> Category    which kind of app the text is going into
//     AppStyles.apply(_:to:) -> String                          format text in a style
//
//   Formal      "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
//               In email, "Hi Marcus, thanks for..." becomes "Hi Marcus,\n\nThanks for..."
//   Casual      same, without the final period
//   Very casual same as casual, with sentence starts in lowercase ("I" and names keep their capitals)
//   As spoken   unchanged

enum AppStyles {
    enum Style: String, CaseIterable {
        case formal, casual, veryCasual, asSpoken
        var label: String {
            switch self {
            case .formal: return "Formal"
            case .casual: return "Casual"
            case .veryCasual: return "Very casual"
            case .asSpoken: return "As spoken (no change)"
            }
        }
    }

    enum Category: String, CaseIterable {
        case email, workChat, texts, other
        var label: String {
            switch self {
            case .email: return "Email"
            case .workChat: return "Work chat"
            case .texts: return "Texts"
            case .other: return "Everything else"
            }
        }
        var defaultStyle: Style {
            switch self {
            case .email: return .formal
            case .workChat, .texts: return .casual
            case .other: return .asSpoken
            }
        }
    }

    static let emailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.SparkDesktop", "com.readdle.smartemail-Mac",
        "com.superhuman.electron", "com.mimestream.Mimestream", "it.bloop.airmail2", "com.google.Gmail",
    ]
    static let workChatApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.Discord",
        "com.google.Chat",
    ]
    static let textApps: Set<String> = [
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram",
        "org.telegram.desktop", "com.facebook.archon", "org.whispersystems.signal-desktop",
    ]
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// In a browser, the window title tells which web app is in front ("Inbox (3) - you@x.com - Gmail").
    static func category(bundleID: String?, windowTitle: String?) -> Category {
        guard let id = bundleID else { return .other }
        if emailApps.contains(id) { return .email }
        if workChatApps.contains(id) { return .workChat }
        if textApps.contains(id) { return .texts }
        if browsers.contains(id), let t = windowTitle?.lowercased() {
            if t.contains("gmail") || t.contains("outlook") || t.contains("yahoo mail") || t.contains("icloud mail") { return .email }
            if t.contains("slack") || t.contains("microsoft teams") || t.contains("google chat") { return .workChat }
            if t.contains("whatsapp") || t.contains("messenger") || t.contains("google messages") { return .texts }
        }
        return .other
    }

    static func apply(_ style: Style, to text: String, category: Category = .other) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return text }
        switch style {
        case .asSpoken:
            return text
        case .formal:
            var out = endWithPeriod(t)
            if category == .email { out = greetingOnOwnLine(out) }
            return out
        case .casual:
            return dropFinalPeriod(t)
        case .veryCasual:
            return lowercaseSentenceStarts(dropFinalPeriod(t))
        }
    }

    // MARK: rules

    /// Adds a period when the text ends on a plain word, and only then: never after a link, an email address,
    /// a number, a list or text that already ends in punctuation.
    static func endWithPeriod(_ t: String) -> String {
        guard let last = t.last, last.isLetter else { return t }
        let lastLine = t.components(separatedBy: "\n").last ?? t
        if lastLine.range(of: #"^\s*(\d+[.)]|[-•*])\s"#, options: .regularExpression) != nil { return t }   // list item
        let lastToken = lastLine.split(separator: " ").last.map(String.init) ?? ""
        if lastToken.contains("@") || lastToken.contains("://") || lastToken.contains("www.") || lastToken.contains("/") { return t }
        if t.split(whereSeparator: \.isWhitespace).count < 3 { return t }   // "Thanks" / "Sounds good" stay as said
        return t + "."
    }

    /// Removes one final period. Keeps "...", abbreviations ("4 p.m.", "U.S."), "?" and "!".
    static func dropFinalPeriod(_ t: String) -> String {
        guard t.hasSuffix("."), !t.hasSuffix("..") else { return t }
        if t.range(of: #"(^|[\s(])([A-Za-z]\.){2,}$"#, options: .regularExpression) != nil { return t }   // a.m. / U.S.
        if t.range(of: #"\b(etc|vs|Mr|Mrs|Ms|Dr|Jr|Sr|Inc|Ltd|Co)\.$"#, options: .regularExpression) != nil { return t }
        return String(t.dropLast())
    }

    /// Lowercases the first letter of each sentence, unless it's "I" ("I'm", "I'll") or the word is a name
    /// that appears capitalized somewhere else mid-sentence too.
    static func lowercaseSentenceStarts(_ t: String) -> String {
        var chars = Array(t)
        var atStart = true
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if atStart && c.isLetter {
                let word = String(chars[i...].prefix { $0.isLetter || $0 == "'" })
                let keep = word == "I" || word.hasPrefix("I'") || isNameElsewhere(word, in: t)
                    || (word.count > 1 && word == word.uppercased())   // acronyms: FHA, DTI
                if !keep { chars[i] = Character(c.lowercased()) }
                atStart = false
            } else if ".!?\n".contains(c) {
                atStart = true
            } else if !c.isWhitespace && !"\"'(".contains(c) {
                atStart = false
            }
            i += 1
        }
        return String(chars)
    }

    private static func isNameElsewhere(_ word: String, in text: String) -> Bool {
        // Appears capitalized after a lowercase word somewhere = it's a name, not just a sentence start.
        let rx = #"[a-z,]\s+"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#
        return text.range(of: rx, options: .regularExpression) != nil
    }

    /// "Hi Marcus, thanks for..." → "Hi Marcus,\n\nThanks for...". Greeting plus at most three name words,
    /// ending in a comma; only when something follows on the same line.
    static func greetingOnOwnLine(_ t: String) -> String {
        let pattern = #"^((?:Hi|Hello|Hey|Dear|Good (?:morning|afternoon|evening))(?: (?:[A-Z][\w'-]*|team|everyone|all|there)){0,3}),[ ]+(\S)"#
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let greet = Range(m.range(at: 1), in: t), let next = Range(m.range(at: 2), in: t) else { return t }
        let rest = t[next.lowerBound...]
        return t[greet] + ",\n\n" + rest.prefix(1).uppercased() + rest.dropFirst()
    }
}
