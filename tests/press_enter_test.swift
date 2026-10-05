import Foundation
// "press enter": it counts only when said on its own (press Return, paste nothing). No mic, no UI.
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
        // the whole dictation is the command: press Return, paste nothing
        check("Press enter.", "", true)
        check("press enter", "", true)
        check("Press Enter", "", true)
        check("Press return.", "", true)
        check("Press, enter.", "", true)
        check(" press enter ", "", true)
        // anything else is just text: never paste and send in one step
        check("Sounds good, see you at three. Press enter.", "Sounds good, see you at three. Press enter.", false)
        check("Sounds good, press enter", "Sounds good, press enter", false)
        check("sounds good press enter", "sounds good press enter", false)
        check("Thanks so much! Press return.", "Thanks so much! Press return.", false)
        check("Ask them to. Press enter.", "Ask them to. Press enter.", false)
        check("Tell them to press enter.", "Tell them to press enter.", false)
        check("Press enter to log in, then check the rate.", "Press enter to log in, then check the rate.", false)
        check("Don't press enter yet.", "Don't press enter yet.", false)
        check("Press enter now.", "Press enter now.", false)
        check("The press entered the room.", "The press entered the room.", false)
        check("Express return policy", "Express return policy", false)
        check("", "", false)
        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
