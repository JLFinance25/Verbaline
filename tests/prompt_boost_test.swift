import Foundation

// prompt_boost_test: the "make this prompt better" trigger.
//   prompt_boost_test            trigger rules only (instant)
//   prompt_boost_test --ai       also rewrites sample prompts with the on-device AI and checks the results
// Exit 0 = all PASS.

@main struct PromptBoostTest {
    static var failed = 0
    static func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL")  \(name)"); if !ok { failed += 1 } }

    static func main() async {
        let base = "Write me a follow-up email to a borrower about their missing W-2"
        let triggers = [
            "\(base). Make this prompt better.", "\(base), make this prompt better", "\(base). Make this a better prompt.",
            "\(base). Improve this prompt.", "\(base). Okay, make this prompt better please.", "\(base) make it a better prompt",
            "\(base). Now improve my prompt!", "\(base). So make this prompt clearer.", "\(base). Make this into a better prompt.",
            "\(base). Polish this prompt.", "\(base). Rewrite the prompt.", "\(base) MAKE THIS PROMPT BETTER",
        ]
        for t in triggers {
            let r = PromptBoost.split(t)
            check(r.boost && r.text.hasPrefix("Write me a follow-up email") && r.text.count <= base.count + 1,
                  "triggers: \"\(t)\" → \"\(r.text)\"")
        }
        let plain = [
            base, "Make this prompt better than the last one we sent to the lender.",
            "I need you to fix the prompt.", "The prompt is better now.", "Can you make this prompt better for the team tomorrow?",
            "We should improve this prompt next week.", "Make this better.", "This is a better prompt.",
        ]
        for t in plain {
            let r = PromptBoost.split(t)
            check(!r.boost && r.text == t, "doesn't trigger: \"\(t)\"")
        }
        let only = PromptBoost.split("Make this prompt better.")
        check(only.boost && only.text.isEmpty, "trigger alone → boost with no text")

        guard CommandLine.arguments.contains("--ai") else { finish() }

        // Leak and answer checks catch bad rewrites.
        check(PromptBoost.Checks.problem(input: "plan my week", output: "Dear team, here is the plan") != nil, "check: an answer is rejected")
        check(PromptBoost.Checks.problem(input: "email about 3 files", output: "Write an email about 4 files.\nContext: none.\nI want: short.") != nil, "check: invented number rejected")
        check(PromptBoost.Checks.problem(input: "email the lender about the 3 missing statements",
              output: "Write an email to the lender about the 3 missing statements.\nI want: a short, polite email.") == nil, "check: a good rewrite is accepted")
        check(PromptBoost.Checks.problem(input: "email the borrower about their W-2",
              output: "Write an email to the borrower about their W-2.\nContext: they need to send it by Friday.\nI want: a short email.") != nil, "check: invented deadline rejected")
        check(PromptBoost.Checks.problem(input: "email the borrower about their W-2",
              output: "Write an email to the borrower about their W-2.\nContext: the borrower is Sarah.\nI want: a short email.") != nil, "check: invented name rejected")
        let samples = [
            "write me a follow up email to a borrower about their missing W-2 and the closing is on the 14th",
            "give me five ideas for linkedin posts about first time home buyers in a casual tone",
            "explain the difference between a fixed and adjustable rate mortgage for someone who's never bought a house",
            "help me plan my week I have three closings and a team meeting on Wednesday",
            "draft a linkedin post celebrating a client who just closed on their first home in Austin keep it humble",
            "what questions should I ask a self employed borrower before preapproval",
            "rewrite my bio so it sounds more professional but still friendly I've been a loan officer for 6 years",
            "make a checklist of documents a buyer needs for a VA loan",
        ]
        var improved = 0
        for s in samples {
            let t0 = Date()
            let out = await PromptBoost.improve(s)
            let secs = Date().timeIntervalSince(t0)
            switch out {
            case .improved(let t):
                improved += 1
                let numbersIn = Set(s.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty })
                let numbersOut = Set(t.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty })
                let answered = t.lowercased().hasPrefix("dear") || t.lowercased().hasPrefix("subject:") || t.lowercased().hasPrefix("1. ")
                print(String(format: "      %.1f s  IN : %@\n             OUT: %@", secs, s, t.replacingOccurrences(of: "\n", with: " ⏎ ")))
                check(numbersOut.isSubset(of: numbersIn), "no invented numbers")
                check(numbersIn.isSubset(of: numbersOut), "keeps every number it was given")
                check(!answered, "rewrote the prompt instead of answering it")
                check(t.count >= s.count * 9 / 10, "didn't throw away the request (\(t.count) vs \(s.count) chars)")
            case .keptAsSaid(let why):
                // Safe outcome: the words get pasted as said. Counted below, not a failure by itself.
                print("      \(String(format: "%.1f", secs)) s  IN : \(s)\n             KEPT AS SAID: \(why)")
            }
        }
        check(improved * 4 >= samples.count * 3, "at least 75% of prompts improved (\(improved) of \(samples.count))")
        finish()
    }

    static func finish() -> Never {
        print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
