import Foundation

// app_styles_test: per-app writing styles. Rules only; a style may change capitals, a final period and the
// greeting line break, never a word or a number. Exit 0 = all PASS.

@main struct AppStylesTest {
    static var failed = 0
    static func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL")  \(name)"); if !ok { failed += 1 } }
    static func eq(_ style: AppStyles.Style, _ input: String, _ want: String, _ cat: AppStyles.Category = .other) {
        let got = AppStyles.apply(style, to: input, category: cat)
        check(got == want, "\(style.rawValue): \"\(input)\" → \"\(got.replacingOccurrences(of: "\n", with: "⏎"))\"")
    }
    /// Same words and numbers, ignoring case, punctuation and line breaks.
    static func sameWords(_ a: String, _ b: String) -> Bool {
        func w(_ s: String) -> [String] { s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty } }
        return w(a) == w(b)
    }

    static func main() {
        // Wispr's own example sentence.
        let lunch = "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
        eq(.formal, lunch, lunch)
        eq(.casual, lunch, "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you")
        eq(.veryCasual, lunch, "hey, are you free for lunch tomorrow? let's do 12 if that works for you")
        eq(.asSpoken, lunch, lunch)

        // Formal adds a period only after a plain word.
        eq(.formal, "Please send the last two pay stubs", "Please send the last two pay stubs.")
        eq(.formal, "Are we still closing Friday?", "Are we still closing Friday?")
        eq(.formal, "Sounds good", "Sounds good")
        eq(.formal, "Here is the link https://example.com/apply", "Here is the link https://example.com/apply")
        eq(.formal, "Email it to sarah@example.com", "Email it to sarah@example.com")
        eq(.formal, "The rate is 6.75", "The rate is 6.75")
        eq(.formal, "Three things:\n1. Pay stubs\n2. Bank statements", "Three things:\n1. Pay stubs\n2. Bank statements")

        // Formal email: greeting on its own line.
        eq(.formal, "Hi Marcus, thanks for sending the documents. I'll review them tonight",
           "Hi Marcus,\n\nThanks for sending the documents. I'll review them tonight.", .email)
        eq(.formal, "Hey team, the appraisal came back", "Hey team,\n\nThe appraisal came back.", .email)
        eq(.formal, "Hi Marcus, thanks", "Hi Marcus,\n\nThanks.", .email)
        eq(.formal, "Hi Marcus, thanks for the update", "Hi Marcus, thanks for the update.", .texts)   // not email: one line

        // Casual keeps abbreviations, ellipses, questions.
        eq(.casual, "Let's talk at 4 p.m.", "Let's talk at 4 p.m.")
        eq(.casual, "It's a U.S.", "It's a U.S.")
        eq(.casual, "Bring your W-2, pay stubs, etc.", "Bring your W-2, pay stubs, etc.")
        eq(.casual, "Hmm...", "Hmm...")
        eq(.casual, "Did you get it?", "Did you get it?")
        eq(.casual, "Got it. Talk soon.", "Got it. Talk soon")

        // Very casual keeps I, names and acronyms.
        eq(.veryCasual, "I'll call you later. Thanks.", "I'll call you later. thanks")
        eq(.veryCasual, "Sarah called. Tell Sarah the FHA quote is ready.", "Sarah called. tell Sarah the FHA quote is ready")
        eq(.veryCasual, "FHA is fine. Call me.", "FHA is fine. call me")

        // No style ever changes a word or a number.
        let samples = [lunch, "Hi Marcus, the rate is 6.75% on a 30-year fixed and the DTI is 41%. Closing is March 14th",
                       "Send the W-2 to sarah@example.com by 5 p.m.", "Okay. I mean, it's fine. Call Mike."]
        for s in samples {
            for st in AppStyles.Style.allCases {
                for c in AppStyles.Category.allCases {
                    if !sameWords(s, AppStyles.apply(st, to: s, category: c)) { check(false, "words unchanged: \(st) \(c) \(s)") }
                }
            }
        }
        check(true, "no style changes any word or number (\(samples.count * 16) combinations)")

        // App categories.
        check(AppStyles.category(bundleID: "com.apple.mail", windowTitle: nil) == .email, "Mail → email")
        check(AppStyles.category(bundleID: "com.google.Chrome", windowTitle: "Inbox (3) - me@x.com - Gmail") == .email, "Gmail in Chrome → email")
        check(AppStyles.category(bundleID: "com.google.Chrome", windowTitle: "Zillow") == .other, "other site → other")
        check(AppStyles.category(bundleID: "com.apple.MobileSMS", windowTitle: nil) == .texts, "Messages → texts")
        check(AppStyles.category(bundleID: "com.tinyspeck.slackmacgap", windowTitle: nil) == .workChat, "Slack → work chat")
        check(AppStyles.category(bundleID: nil, windowTitle: nil) == .other, "unknown → other")
        check(AppStyles.Category.texts.defaultStyle == .casual && AppStyles.Category.email.defaultStyle == .formal
              && AppStyles.Category.other.defaultStyle == .asSpoken, "defaults: email formal, texts casual, other unchanged")

        print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
