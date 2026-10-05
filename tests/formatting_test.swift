import Foundation
// Spoken formatting + snippets + the shared pipeline (rules only, so results are exact). No mic, no UI.
@main struct FormattingTest {
    static func main() async {
        var fails = 0
        func check(_ name: String, _ got: String, _ want: String) {
            let ok = got == want
            print((ok ? "PASS  " : "FAIL  ") + name + (ok ? "" : "\n      got:  \(got.debugDescription)\n      want: \(want.debugDescription)"))
            if !ok { fails += 1 }
        }
        let F = SpokenFormatting.self
        // commands
        check("new line keeps the comma before it", F.apply("Hi Sarah, new line, thanks for the documents."), "Hi Sarah,\nThanks for the documents.")
        check("new paragraph", F.apply("Thanks for your help. New paragraph. Best, Alex."), "Thanks for your help.\n\nBest, Alex.")
        check("bullets after a colon", F.apply("Things to bring: bullet point pay stubs, bullet point bank statements."), "Things to bring:\n• Pay stubs\n• Bank statements.")
        check("bullet at the very start", F.apply("Bullet point pay stubs. Bullet point W-2s."), "• Pay stubs.\n• W-2s.")
        check("no punctuation around command", F.apply("Call me new line thanks"), "Call me\nThanks")
        check("'newline' as one word", F.apply("First part newline second part"), "First part\nSecond part")
        // ordinary speech must be left alone
        for s in ["We're launching a new line of loans.", "The bullet point is clear.", "Add a new paragraph about rates.",
                  "Open a new line of credit", "That bullet point matters", "Our new line is live."] {
            check("left alone: \(s)", F.apply(s), s)
            check("no command in: \(s)", F.containsCommand(s) ? "yes" : "no", "no")
        }

        // snippets
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verbaline-fmt-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snipFile = dir.appendingPathComponent("snippets.txt")
        try! """
        # notes at the top
        [insert my signature]
        Alex Example
        Loan Officer · NMLS #000000

        [my calendar link]
        # a note inside is ignored
        https://cal.example.com/alex?x=$1&y=\\n

        [insert my signature block]
        LONGER WINS

        [insert my nmls]
        NMLS #000000

        [superfast demo]
        DEMO

        [paste my disclaimer]
        Rates subject to change. fanny may new line 6.5% APR.
        """.write(to: snipFile, atomically: true, encoding: .utf8)
        let dictFile = dir.appendingPathComponent("dictionary.txt")
        try! "fanny may -> Fannie Mae\nescrow\n".write(to: dictFile, atomically: true, encoding: .utf8)

        let snippets = Snippets(fileURL: snipFile)
        let dictionary = PersonalDictionary(fileURL: dictFile)
        let cleaner = TextCleaner()
        func run(_ raw: String, ai: Bool = false) async -> String {
            await TextPipeline.finish(raw, useAI: ai, cleaner: cleaner, dictionary: dictionary, snippets: snippets).text
        }
        check("parsed snippet count", "\(Snippets.parseForTesting(try! String(contentsOf: snipFile, encoding: .utf8)).count)", "6")
        check("acronym spelled with dots", await run("Insert my N.M.L.S."), "NMLS #000000")
        check("acronym split by a space", await run("Insert my NM LS."), "NMLS #000000")
        check("one word heard as two", await run("Super fast demo."), "DEMO")
        check("signature on its own line", await run("Thanks for your time. New line. Insert my signature."),
              "Thanks for your time.\nAlex Example\nLoan Officer · NMLS #000000")
        check("symbols in snippet kept exactly ($1, \\n, ?)", await run("Book a time here: my calendar link."),
              "Book a time here: https://cal.example.com/alex?x=$1&y=\\n")
        check("longest trigger wins", await run("Insert my signature block."), "LONGER WINS")
        check("any case, trailing punctuation", await run("INSERT MY SIGNATURE!"), "Alex Example\nLoan Officer · NMLS #000000")
        check("no match inside a longer word", await run("insert my signatures"), "Insert my signatures")
        check("dictionary + formatting never touch snippet text", await run("Paste my disclaimer."),
              "Rates subject to change. fanny may new line 6.5% APR.")
        check("dictionary still fixes the rest", await run("um fanny may handles escrow. Paste my disclaimer."),
              "Fannie Mae handles escrow. Rates subject to change. fanny may new line 6.5% APR.")
        check("no trigger → unchanged pipeline", await run("um so the rate is locked"), "So the rate is locked")
        // the "Fixed" pill: only real word swaps from heard -> written lines are reported
        func fixes(_ raw: String) async -> String {
            await TextPipeline.finish(raw, useAI: false, cleaner: cleaner, dictionary: dictionary, snippets: snippets)
                .fixes.map { "\($0.from)→\($0.to)" }.joined(separator: ",")
        }
        check("reports a replacement-line swap (as it appeared)", await fixes("fanny may handles it"), "Fanny may→Fannie Mae")
        check("plain-term casing isn't reported", await fixes("we need escrow"), "")
        check("nothing to fix → nothing reported", await fixes("the rate is locked"), "")
        check("snippet text swaps aren't reported", await fixes("Paste my disclaimer."), "")
        // the AI is skipped whenever a snippet or a formatting command is used
        _ = await run("Insert my signature.", ai: true)
        check("AI skipped for snippet dictation", cleaner.lastDiagnostic, "rules only (LLM not requested)")
        _ = await run("Hi Sarah, new line, thanks.", ai: true)
        check("AI skipped for formatting dictation", cleaner.lastDiagnostic, "rules only (LLM not requested)")
        // file edits are picked up
        try! "[say hello snippet]\nHELLO\n".write(to: snipFile, atomically: true, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 1_100_000_000)   // modification dates have 1 s resolution on some volumes
        try! "[say hello snippet]\nHELLO AGAIN\n".write(to: snipFile, atomically: true, encoding: .utf8)
        check("reload after editing the file", await run("Say hello snippet."), "HELLO AGAIN")

        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
