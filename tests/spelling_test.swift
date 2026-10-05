import Foundation
// "spell" + letters → one word. Inputs are the shapes Apple's recognizer actually produced from spelled
// speech (tested with `say` voices), plus ordinary sentences that must be left alone. No mic, no UI.
@main struct SpellingTest {
    static func main() {
        var fails = 0
        func check(_ input: String, _ want: String) {
            let got = Spelling.apply(input).text
            let ok = got == want
            print((ok ? "PASS  " : "FAIL  ") + input.debugDescription
                  + (ok ? "" : "\n      got:  \(got.debugDescription)\n      want: \(want.debugDescription)"))
            if !ok { fails += 1 }
        }
        // recognizer shapes
        check("Spell H E-L-O-C.", "HELOC.")
        check("Spell H E L O C.", "HELOC.")
        check("Spell, H, E, L, O, C.", "HELOC.")
        check("Please email spell K-ER-G-ER about the appraisal.", "Please email Kerger about the appraisal.")
        check("Spell WYQUR.", "WYQUR.")
        check("Our license is spell N M L S, and it is on file.", "Our license is NMLS, and it is on file.")
        check("Send it to spell age, E, L, O, C today.", "Send it to HELOC today.")
        check("Spell H. E. L. O. C. Thanks.", "HELOC. Thanks.")
        check("Talk to spell M O R G A N tomorrow.", "Talk to Morgan tomorrow.")
        check("spell m o r g a n", "Morgan")
        check("Ask about spell F H A loans.", "Ask about FHA loans.")
        check("First spell N M L S then spell H E L O C.", "First NMLS then HELOC.")
        // case rule: 5 or fewer letters in capitals, 6 or more with a capital first letter
        check("spell A B C D E", "ABCDE")
        check("spell A B C D E F", "Abcdef")
        // left alone
        for s in ["Can you spell that for me?", "I never could spell well.", "How do you spell HELOC?",
                  "Spell a word for me.", "Spell it out.", "We had a dry spell in March.", "She cast a spell on him.",
                  "That spell lasted a while.", "Spell check is on.", "I'll spell X later.", "You have to spell it right.",
                  "Spell in English.", ""] {
            check(s, s)
        }
        // shielding round trip
        let (spelled, words) = Spelling.apply("Email spell K E R G E R and spell N M L S.")
        let shielded = Spelling.shield(spelled, words)
        let noLetters = !shielded.text.contains("Kerger") && !shielded.text.contains("NMLS")
        let back = Spelling.unshield(shielded.text, shielded.words)
        if !noLetters || back != "Email Kerger and NMLS." {
            print("FAIL  shield round trip\n      shielded: \(shielded.text.debugDescription)\n      back: \(back.debugDescription)")
            fails += 1
        } else {
            print("PASS  shield round trip")
        }
        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
