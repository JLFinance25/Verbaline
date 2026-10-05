import Foundation
// "press enter" at the end of a dictation: when it counts as a command, and what text is left to paste. No mic, no UI.
@main struct PressEnterTest {
    static func main() {
        var fails = 0
        func check(_ input: String, _ wantText: String, _ wantEnter: Bool) {
            let got = PressEnter.split(input)
            let ok = got.text == wantText && got.pressEnter == wantEnter
            print((ok ? "PASS  " : "FAIL  ") + input.debugDescription
                  + (ok ? "" : "\n      got:  \(got.text.debugDescription) enter=\(got.pressEnter)"
                              + "\n      want: \(wantText.debugDescription) enter=\(wantEnter)"))
            if !ok { fails += 1 }
        }
        // sends
        check("Sounds good, see you at three. Press enter.", "Sounds good, see you at three.", true)
        check("Sounds good, press enter", "Sounds good", true)
        check("sounds good press enter", "sounds good", true)
        check("On my way. Press Enter", "On my way.", true)
        check("Thanks so much! Press return.", "Thanks so much!", true)
        check("Running late press, enter.", "Running late", true)
        check("Press enter.", "", true)
        check("press enter", "", true)
        check("Ask them to. Press enter.", "Ask them to.", true)   // a sentence break: the user is giving the command
        // left alone
        check("Tell them to press enter.", "Tell them to press enter.", false)
        check("You press enter and it logs you in.", "You press enter and it logs you in.", false)
        check("Press enter to log in, then check the rate.", "Press enter to log in, then check the rate.", false)
        check("Type your password and press enter.", "Type your password and press enter.", false)
        check("Just press enter.", "Just press enter.", false)
        check("Please press enter.", "Please press enter.", false)
        check("You should press return.", "You should press return.", false)
        check("Don't press enter yet.", "Don't press enter yet.", false)
        check("The press entered the room.", "The press entered the room.", false)
        check("Express return policy", "Express return policy", false)
        check("Hit the press release, enter it.", "Hit the press release, enter it.", false)
        check("", "", false)
        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
