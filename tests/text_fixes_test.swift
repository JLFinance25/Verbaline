import Foundation
// Pins the bugs found in the October review so they can't come back. Rules-only + guard; no model calls.
@main struct TextFixesTest {
    static func main() async {
        var fails = 0
        func check(_ name: String, _ got: String, _ want: String) {
            let ok = got == want
            print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "\n      got:  \(got)\n      want: \(want)"))
            if !ok { fails += 1 }
        }
        func guardCheck(_ name: String, out: String, input: String, accept: Bool) {
            let verdict = LLMGuard.check(out, against: input)
            var accepted = false, why = ""
            switch verdict { case .accept: accepted = true; case .reject(let r): why = r }
            let ok = accepted == accept
            print((ok ? "PASS  " : "FAIL  ") + "guard: \(name) → \(accepted ? "accept" : "reject (\(why))")")
            if !ok { fails += 1 }
        }
        let c = TextCleaner()
        func rules(_ s: String) async -> String { await c.clean(s, useLLM: false) }

        // "delete that" is only a command when it stands alone
        check("question with 'delete that' kept", await rules("Can you delete that?"), "Can you delete that?")
        check("'delete that' mid-sentence kept", await rules("I told her to delete that, but she didn't"), "I told her to delete that, but she didn't")
        check("'please delete that.' kept", await rules("Please delete that."), "Please delete that.")
        check("standalone 'Delete that.' still a command", await rules("Send it to John. Delete that. Send it to Sarah."), "Send it to Sarah.")
        // "scratch that" across abbreviations
        check("scratch that after 'p.m.' drops the old time", await rules("Closing is at 3 p.m. on Friday scratch that closing is at 4 p.m."), "Closing is at 4 p.m.")
        check("scratch that after 'Mr.'", await rules("Send it to Mr. Smith scratch that send it to Mr. Jones"), "Send it to Mr. Jones")
        check("scratch that (existing case)", await rules("buy milk eggs and bread scratch that buy milk and eggs"), "Buy milk and eggs")
        // spelled-out numbers aren't stutters
        check("spelled phone number intact", await rules("call me at five five five one two three four"), "Call me at five five five one two three four")
        check("'twenty twenty' intact", await rules("since twenty twenty"), "Since twenty twenty")
        // acronyms aren't fillers
        check("ER kept", await rules("I took her to the ER yesterday"), "I took her to the ER yesterday")
        check("MH kept", await rules("Fannie Mae MH Advantage loans"), "Fannie Mae MH Advantage loans")
        check("real fillers still removed", await rules("um so I was thinking uh we should we should move the meeting to Thursday"), "So I was thinking we should move the meeting to Thursday")
        // punctuation
        check("URL query string intact", await rules("visit example.com/apply?ref=alex today"), "Visit example.com/apply?ref=alex today")
        check("no capital after etc.", await rules("bank statements, pay stubs, etc. and a letter"), "Bank statements, pay stubs, etc. and a letter")
        check("question spacing still fixed", await rules("really?yes it is"), "Really? Yes it is")

        // number guard
        guardCheck("correction keeps final time", out: "Let's meet at 3 o'clock.", input: "Let's meet at 2, actually make that 3 o'clock.", accept: true)
        guardCheck("correction keeps final rate", out: "The rate is 6.75% on a 30-year fixed.", input: "The rate is 6.5% no actually 6.75% on a 30-year fixed", accept: true)
        guardCheck("list markers don't count", out: "Three things:\n1. Call the client.\n2. Update the CRM.", input: "Three things. First, call the client. Second, update the CRM.", accept: true)
        guardCheck("keeps the wrong (old) rate", out: "The rate is 6.5.", input: "The rate is 6.5 no wait 6.75", accept: false)
        guardCheck("swaps two rates", out: "It went from 6.75 to 6.5.", input: "It went from 6.5 to 6.75", accept: false)
        guardCheck("drops the k", out: "The price is $450.", input: "The price is $450k", accept: false)
        guardCheck("scrambles a phone number", out: "Call 555-4567-123.", input: "Call 555-123-4567", accept: false)
        guardCheck("swaps date parts", out: "Closing is 12/10/2025.", input: "Closing is 10/12/2025", accept: false)
        guardCheck("drops numbers with no correction", out: "The rate is good and the payment is fine.", input: "The rate is 6.5% and the payment is $2,450", accept: false)
        guardCheck("invents a number", out: "Your payment is $2,450 a month.", input: "Your payment is about two thousand a month", accept: false)

        // fast path
        check("'I meant' needs the model", TextCleaner.needsModel("The rate is 6.5 I meant 6.75") ? "yes" : "no", "yes")
        check("digit repeat alone doesn't need the model", TextCleaner.needsModel("the 5 the 5 rate") ? "yes" : "no", "no")
        check("plain sentence skips the model", TextCleaner.needsModel("Hello, how is this all working out?") ? "yes" : "no", "no")

        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
