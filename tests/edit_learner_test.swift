import AppKit

// CLI harness for EditLearner.
//
// Build and run from the project root:
//   swiftc -swift-version 5 -O -target arm64-apple-macos26.0 -parse-as-library \
//       src/EditLearner.swift tests/edit_learner_test.swift -o build/edit_learner/edit_learner_test
//   build/edit_learner/edit_learner_test
//
// Every case is "pasted text" + "edited text" -> the exact list of (heard, written) corrections
// EditLearner must return (an empty list means: learn nothing). Prints PASS/FAIL per case, then
// "ALL PASS" or "N FAILED"; exit code 0 / 1.
//
// NSSpellChecker note: NSApplication.shared is created first, as a precaution. (A probe showed
// NSSpellChecker answers correctly in a plain CLI without it too, but creating it is cheap and
// matches how the real app runs, so the harness does it.)
//
// The "ground truth" section at the top checks the spell-checker behaviour EditLearner relies on.
// If one of those fails on another Mac, the cases below it can legitimately differ.

struct Case {
    let name: String
    let pasted: String
    let edited: String
    let expect: [(String, String)]
    init(_ name: String, _ pasted: String, _ edited: String, _ expect: [(String, String)] = []) {
        self.name = name; self.pasted = pasted; self.edited = edited; self.expect = expect
    }
}

var passed = 0
var failed = 0

func show(_ list: [(String, String)]) -> String {
    list.isEmpty ? "[]" : "[" + list.map { "\"\($0.0)\" -> \"\($0.1)\"" }.joined(separator: ", ") + "]"
}

func run(_ c: Case) {
    let got = EditLearner.corrections(pasted: c.pasted, edited: c.edited).map { ($0.heard, $0.written) }
    let ok = got.count == c.expect.count && zip(got, c.expect).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    if ok {
        passed += 1
        print("  PASS  \(c.name)" + (got.isEmpty ? "   (learns nothing)" : "   -> \(show(got))"))
    } else {
        failed += 1
        print("  FAIL  \(c.name)\n          pasted : \(c.pasted)\n          edited : \(c.edited)\n          got    : \(show(got))\n          wanted : \(show(c.expect))")
    }
}

func fact(_ name: String, _ ok: Bool) {
    if ok { passed += 1; print("  PASS  \(name)") } else { failed += 1; print("  FAIL  \(name)") }
}

func section(_ title: String) { print("\n== \(title) ==") }

@main
struct EditLearnerTest {
    static func main() {
        _ = NSApplication.shared
        let sc = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        func accepts(_ w: String) -> Bool {
            sc.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                             inSpellDocumentWithTag: tag, wordCount: nil).location == NSNotFound
        }

        // ---------------------------------------------------------------------------------
        section("ground truth: what NSSpellChecker (language \"en\") says")
        fact("English dictionary is available", sc.availableLanguages.contains("en"))
        fact("acronyms in capitals are accepted (HELOC DTI LTV NMLS)", ["HELOC", "DTI", "LTV", "NMLS"].allSatisfy(accepts))
        fact("... but their lowercase forms are not (heloc dti ltv nmls)", ["heloc", "dti", "ltv", "nmls"].allSatisfy { !accepts($0) })
        fact("any all-caps string is accepted (XQZV), so all-caps needs the lowercase test", accepts("XQZV") && !accepts("xqzv"))
        fact("proper nouns accepted capitalized, not lowercase (Sarah Zhang Fannie Mae)",
             ["Sarah", "Zhang", "Fannie", "Mae"].allSatisfy(accepts) && ["sarah", "zhang", "fannie", "mae"].allSatisfy { !accepts($0) })
        fact("Nicholson accepted, nicholson not", accepts("Nicholson") && !accepts("nicholson"))
        fact("Helllock and Nikolsen are misspellings", !accepts("Helllock") && !accepts("Nikolsen"))
        fact("everyday words accepted in lowercase (may will grant fixed there mortgage earnest)",
             ["may", "will", "grant", "fixed", "there", "mortgage", "earnest"].allSatisfy(accepts))

        // ---------------------------------------------------------------------------------
        section("1. what must be LEARNED (the brief's examples)")
        run(Case("Helllock -> HELOC",
                 "We can finance the renovation through a Helllock on your primary home.",
                 "We can finance the renovation through a HELOC on your primary home.",
                 [("Helllock", "HELOC")]))
        run(Case("he lock -> HELOC",
                 "You could also open a he lock on the rental property.",
                 "You could also open a HELOC on the rental property.",
                 [("he lock", "HELOC")]))
        run(Case("Nicholson -> Nikolsen",
                 "Please send the signed disclosures to Daniel Nicholson before noon.",
                 "Please send the signed disclosures to Daniel Nikolsen before noon.",
                 [("Nicholson", "Nikolsen")]))
        run(Case("Fanny May -> Fannie Mae (one phrase, never May -> Mae)",
                 "This product follows the standard Fanny May guidelines for conforming loans.",
                 "This product follows the standard Fannie Mae guidelines for conforming loans.",
                 [("Fanny May", "Fannie Mae")]))
        run(Case("Dee Tee Eye -> DTI (spelled-out letters)",
                 "Your Dee Tee Eye ratio is slightly above the program limit.",
                 "Your DTI ratio is slightly above the program limit.",
                 [("Dee Tee Eye", "DTI")]))
        run(Case("non QM -> non-QM",
                 "We also have a non QM program for self employed borrowers.",
                 "We also have a non-QM program for self employed borrowers.",
                 [("non QM", "non-QM")]))
        run(Case("Ernest money -> earnest money",
                 "The Ernest money deposit is due within three days of acceptance.",
                 "The earnest money deposit is due within three days of acceptance.",
                 [("Ernest", "earnest")]))

        // ---------------------------------------------------------------------------------
        section("2. what must be REJECTED (the brief's examples)")
        run(Case("Nicholson -> Zhang (unrelated name)",
                 "Please send the signed disclosures to Daniel Nicholson before noon.",
                 "Please send the signed disclosures to Daniel Zhang before noon."))
        run(Case("Helllock -> mortgage (unrelated word)",
                 "We can finance the renovation through a Helllock on your primary home.",
                 "We can finance the renovation through a mortgage on your primary home."))
        run(Case("Sarah -> Jessica (different person)",
                 "I will have Sarah call you back this afternoon about the appraisal.",
                 "I will have Jessica call you back this afternoon about the appraisal."))
        run(Case("Monday -> Tuesday (both real words)",
                 "The closing is scheduled for Monday at the title company.",
                 "The closing is scheduled for Tuesday at the title company."))
        run(Case("their -> there (both real words)",
                 "Please confirm that their address is correct on the form.",
                 "Please confirm that there address is correct on the form."))
        run(Case("send -> email (both real words)",
                 "Please send the documents to the borrower today.",
                 "Please email the documents to the borrower today."))
        run(Case("may -> Mae mid-sentence (heard side is one everyday word)",
                 "We may need the guidelines for this file.",
                 "We Mae need the guidelines for this file."))
        run(Case("May -> Mae alone (single everyday word, would fire on normal text)",
                 "The rate lock expires in May according to the lender.",
                 "The rate lock expires in Mae according to the lender."))
        run(Case("will -> Will (single everyday word)",
                 "I think will should handle the closing disclosure.",
                 "I think Will should handle the closing disclosure."))
        run(Case("grant -> Grant (single everyday word)",
                 "We spoke with grant about the gift letter yesterday.",
                 "We spoke with Grant about the gift letter yesterday."))
        run(Case("fixed -> Fixed (case change on an everyday word)",
                 "A fixed rate protects you from market increases over time.",
                 "A Fixed rate protects you from market increases over time."))

        // ---------------------------------------------------------------------------------
        section("3. numbers, links, structure of the edit")
        run(Case("6.5% -> 6.75% (number)",
                 "Today the rate is 6.5% for a thirty year fixed loan with points.",
                 "Today the rate is 6.75% for a thirty year fixed loan with points."))
        run(Case("$2,450 -> $2,540 (number)",
                 "Your estimated monthly payment is $2,450 including taxes and insurance.",
                 "Your estimated monthly payment is $2,540 including taxes and insurance."))
        run(Case("spelled-out digits 30 -> 15 (number)",
                 "A 30 year term keeps the payment lower for most borrowers.",
                 "A 15 year term keeps the payment lower for most borrowers."))
        run(Case("pure insertion: Thanks. -> Thanks so much.",
                 "Thanks for sending the paystubs and the bank statements. Thanks.",
                 "Thanks for sending the paystubs and the bank statements. Thanks so much."))
        run(Case("pure insertion in the middle",
                 "Thanks for sending the paystubs and the bank statements today.",
                 "Thanks for sending the paystubs and also the bank statements today."))
        run(Case("pure deletion",
                 "Thanks for sending the paystubs and the bank statements today please.",
                 "Thanks for sending the paystubs and the bank statements today."))
        run(Case("full rewrite of a sentence",
                 "Please send the signed disclosures to the borrower before noon today.",
                 "Could you forward all remaining paperwork over to the client soon."))
        run(Case("rewrite of half the text that also contains a real fix",
                 "We can close through a Helllock but the borrower needs more reserves first.",
                 "We could close through a HELOC although the client must show additional savings."))
        run(Case("edit elsewhere: pasted region untouched, other sentence added after",
                 "The appraisal came back at value and the loan is clear to close.",
                 "The appraisal came back at value and the loan is clear to close. I also called the title company about the survey."))
        run(Case("edit elsewhere: text added before the untouched pasted region",
                 "The appraisal came back at value and the loan is clear to close.",
                 "Hi Maria, quick update. The appraisal came back at value and the loan is clear to close."))
        run(Case("punctuation only: comma added",
                 "Hello John thanks for calling about the Helllock today.",
                 "Hello John, thanks for calling about the Helllock today."))
        run(Case("punctuation only: period and quotes",
                 "She said the rate is firm for sixty days",
                 "She said, \"the rate is firm for sixty days.\""))
        run(Case("e-mail edit",
                 "Send the file to alex@example.com when you are ready please.",
                 "Send the file to alex@lender.example.com when you are ready please."))
        run(Case("URL edit",
                 "You can apply at https://example.com/apply whenever you like.",
                 "You can apply at https://lender.example.com/apply whenever you like."))
        run(Case("bare domain edit",
                 "You can apply at example.com whenever you like to start.",
                 "You can apply at lender.example.com whenever you like to start."))
        run(Case("empty pasted", "", "Something typed by the user."))
        run(Case("empty edited", "Something that was pasted.", ""))
        run(Case("both empty", "", ""))
        run(Case("whitespace and punctuation only", "  ...  ", " -- "))
        run(Case("identical strings",
                 "We can finance the renovation through a Helllock on your home.",
                 "We can finance the renovation through a Helllock on your home."))

        // ---------------------------------------------------------------------------------
        section("4. position in the text, several fixes, trailing typing")
        let long80 = "Thank you for getting back to me so quickly about the loan. I reviewed the documents you sent over " +
            "this morning and everything looks complete from my side. The credit report is clean and your income is " +
            "well documented. We can move forward with the Helllock as soon as the appraisal comes back and the title " +
            "company confirms the lien position on the property. After that I will schedule the signing and let you " +
            "know exactly what to bring with you. Please call me if anything changes before then, otherwise I will " +
            "be in touch on Friday."
        run(Case("80-word paste, one fix in the middle",
                 long80, long80.replacingOccurrences(of: "Helllock", with: "HELOC"),
                 [("Helllock", "HELOC")]))
        run(Case("80-word paste, fix in the middle plus an unrelated typo-style edit that changes 2 words",
                 long80, long80.replacingOccurrences(of: "Helllock", with: "HELOC")
                     .replacingOccurrences(of: "on Friday", with: "on Monday"),
                 [("Helllock", "HELOC")]))
        run(Case("fix at the very start",
                 "Helllock rates are tied to the prime rate and can change monthly.",
                 "HELOC rates are tied to the prime rate and can change monthly.",
                 [("Helllock", "HELOC")]))
        run(Case("fix at the very end, with its period",
                 "The best option for your situation is probably a Helllock.",
                 "The best option for your situation is probably a HELOC.",
                 [("Helllock", "HELOC")]))
        run(Case("fix followed by a comma",
                 "With a Helllock, the draw period is usually ten years.",
                 "With a HELOC, the draw period is usually ten years.",
                 [("Helllock", "HELOC")]))
        run(Case("three separate fixes in one paste",
                 "We can use a Helllock or a Fanny May loan, and I will send everything to Daniel Nicholson next week once we hear back from underwriting.",
                 "We can use a HELOC or a Fannie Mae loan, and I will send everything to Daniel Nikolsen next week once we hear back from underwriting.",
                 [("Helllock", "HELOC"), ("Fanny May", "Fannie Mae"), ("Nicholson", "Nikolsen")]))
        run(Case("same fix made twice is returned once",
                 "A Helllock is flexible and a second Helllock can be added later when the property value rises further.",
                 "A HELOC is flexible and a second HELOC can be added later when the property value rises further.",
                 [("Helllock", "HELOC")]))
        run(Case("same heard word fixed two different ways: learn neither",
                 "Compare the Helllock with the other Helllock options we discussed earlier this week on our call together.",
                 "Compare the HELOC with the other Helloc options we discussed earlier this week on our call together."))
        run(Case("four separate fixes is a rewrite signal: learn nothing",
                 "A Helllock, a Fanny May loan, a Dee Tee Eye check and Daniel Nicholson will all be covered in this very long message about the file today.",
                 "A HELOC, a Fannie Mae loan, a DTI check and Daniel Nikolsen will all be covered in this very long message about the file today."))
        run(Case("trailing typing right after the fix (rule 3)",
                 "Let me walk you through the options for the home equity line of credit, then talk about the second mortgage and the closing costs through Helllock.",
                 "Let me walk you through the options for the home equity line of credit, then talk about the second mortgage and the closing costs through HELOC. Thanks so much",
                 [("Helllock", "HELOC")]))
        run(Case("trailing typing: fixed word plus a new sentence",
                 "One more thing to cover with you today is the possibility of a Helllock for the kitchen remodel project.",
                 "One more thing to cover with you today is the possibility of a HELOC for the kitchen remodel project. Let me know what you think",
                 [("Helllock", "HELOC")]))
        run(Case("trailing typing with no fix learns nothing",
                 "Thanks for your time today, I will follow up with the numbers.",
                 "Thanks for your time today, I will follow up with the numbers. Talk soon and have a great weekend"))
        run(Case("multi-line paste, fix on the second line",
                 "Hi Maria,\nWe can use a Helllock for this purchase.\nThanks",
                 "Hi Maria,\nWe can use a HELOC for this purchase.\nThanks",
                 [("Helllock", "HELOC")]))
        run(Case("curly quotes and parentheses around the fix",
                 "Our \u{201C}Fanny May\u{201D} guidelines (Helllock excluded) apply here.",
                 "Our \u{201C}Fannie Mae\u{201D} guidelines (HELOC excluded) apply here.",
                 [("Fanny May", "Fannie Mae"), ("Helllock", "HELOC")]))

        // ---------------------------------------------------------------------------------
        section("5. case-only edits")
        run(Case("heloc -> HELOC (not a real word)",
                 "Ask me about a heloc if you own your home outright.",
                 "Ask me about a HELOC if you own your home outright.",
                 [("heloc", "HELOC")]))
        run(Case("dti -> DTI",
                 "Your dti must stay below the program limit for approval.",
                 "Your DTI must stay below the program limit for approval.",
                 [("dti", "DTI")]))
        run(Case("Heloc -> HELOC mid-sentence",
                 "Ask me about a Heloc if you own your home outright.",
                 "Ask me about a HELOC if you own your home outright.",
                 [("Heloc", "HELOC")]))
        run(Case("sarah -> Sarah (not a real word in lowercase)",
                 "Please tell sarah that the appraisal was ordered today.",
                 "Please tell Sarah that the appraisal was ordered today.",
                 [("sarah", "Sarah")]))
        run(Case("heloc -> Heloc mid-sentence (not a known name, and it would also rewrite HELOC)",
                 "Ask me about a heloc if you own your home outright.",
                 "Ask me about a Heloc if you own your home outright."))
        run(Case("dti -> Dti mid-sentence",
                 "Your dti must stay below the program limit for approval.",
                 "Your Dti must stay below the program limit for approval."))
        run(Case("a copy of the word inserted next to it is not a re-casing",
                 "Please send the heloc paperwork and the worksheet to the underwriter today.",
                 "Please send the HELOC heloc paperwork and the worksheet to the underwriter today."))
        run(Case("ambiguous alignment (the same word twice in a row): learn nothing",
                 "Please send the Helllock heloc paperwork to the underwriter today.",
                 "Please send the HELOC HELOC paperwork to the underwriter today."))
        run(Case("a real fix next to a different, untouched word",
                 "Please send the Helllock paperwork to the underwriter today.",
                 "Please send the HELOC paperwork to the underwriter today.",
                 [("Helllock", "HELOC")]))
        run(Case("the -> The mid-sentence (real word)",
                 "Please read the disclosure before you sign anything today.",
                 "Please read The disclosure before you sign anything today."))
        run(Case("sentence-start capitalization never: heloc -> Heloc at the start",
                 "heloc rates are tied to the prime rate and move every month.",
                 "Heloc rates are tied to the prime rate and move every month."))
        run(Case("first-letter capital added at a sentence start inside the text",
                 "We talked about rates. heloc terms came up next in the meeting.",
                 "We talked about rates. Heloc terms came up next in the meeting."))
        run(Case("everyday word shouted: fixed -> FIXED",
                 "A fixed rate protects you from market increases over time.",
                 "A FIXED rate protects you from market increases over time."))
        run(Case("name that is a real word as written: Sarah -> SARAH",
                 "Please tell Sarah that the appraisal was ordered today.",
                 "Please tell SARAH that the appraisal was ordered today."))
        run(Case("long word in capitals is shouting, not an acronym: nikolsen... -> NIKOLSEN",
                 "Please tell Daniel that the Nikolsen file was ordered today.",
                 "Please tell Daniel that the NIKOLSEN file was ordered today."))
        run(Case("bulk uppercase of four words is ignored",
                 "Your heloc dti ltv and fha numbers all look good for this file.",
                 "Your HELOC DTI LTV and FHA numbers all look good for this file."))
        run(Case("acronym lowered: HELOC -> heloc",
                 "Ask me about a HELOC if you own your home outright.",
                 "Ask me about a heloc if you own your home outright."))
        run(Case("acronym un-shouted: HELOC -> Heloc",
                 "Ask me about a HELOC if you own your home outright.",
                 "Ask me about a Heloc if you own your home outright."))

        // ---------------------------------------------------------------------------------
        section("6. more learn cases (spelled letters, similarity, structure)")
        run(Case("D T I -> DTI (single spoken letters)",
                 "Your D T I ratio is slightly above the program limit.",
                 "Your DTI ratio is slightly above the program limit.",
                 [("D T I", "DTI")]))
        run(Case("Ginny May -> Ginnie Mae",
                 "Ginny May securities back all government loans in this program.",
                 "Ginnie Mae securities back all government loans in this program.",
                 [("Ginny May", "Ginnie Mae")]))
        run(Case("Jay Pee Em -> JPM (spoken letter names)",
                 "Our partner Jay Pee Em offers a competitive jumbo product this year.",
                 "Our partner JPM offers a competitive jumbo product this year.",
                 [("Jay Pee Em", "JPM")]))
        run(Case("Mey -> Mae (one letter off in a 3-letter word: too little evidence)",
                 "This product follows the standard Fannie Mey guidelines for conforming loans.",
                 "This product follows the standard Fannie Mae guidelines for conforming loans."))
        run(Case("Fannie Maey -> Fannie Mae (longer word, one letter off)",
                 "This product follows the standard Fannie Maey guidelines for conforming loans.",
                 "This product follows the standard Fannie Mae guidelines for conforming loans.",
                 [("Maey", "Mae")]))
        run(Case("Fanniemae -> Fannie Mae (heard as one word)",
                 "This product follows the standard Fanniemae guidelines for conforming loans.",
                 "This product follows the standard Fannie Mae guidelines for conforming loans.",
                 [("Fanniemae", "Fannie Mae")]))
        run(Case("Beacon -> BECON when the heard word is a real name (N -> U, similar)",
                 "Please check the Nicholson file before the call with the lender today.",
                 "Please check the Nikolsen file before the call with the lender today.",
                 [("Nicholson", "Nikolsen")]))
        run(Case("a pray sal -> appraisal: every word is real, so learn nothing (by the brief's rule 6)",
                 "We ordered a pray sal for the property on Elm Street yesterday.",
                 "We ordered appraisal for the property on Elm Street yesterday."))

        // ---------------------------------------------------------------------------------
        section("7. more reject cases (the ways a bad rule could sneak in)")
        run(Case("HELOC -> HELOCs (just an ending)",
                 "Many lenders offer a HELOC to borrowers with strong equity today.",
                 "Many lenders offer HELOCs to borrowers with strong equity today."))
        run(Case("Nikolsen -> Nikolsen's (possessive)",
                 "I reviewed Nikolsen file and everything looks good so far.",
                 "I reviewed Nikolsen's file and everything looks good so far."))
        run(Case("HELOC -> hemlock (acronym turned into a word)",
                 "Ask me about a HELOC if you own your home outright.",
                 "Ask me about a hemlock if you own your home outright."))
        run(Case("the man -> Themann (common words to a capitalized non-word)",
                 "I spoke with the man about the closing documents yesterday.",
                 "I spoke with Themann about the closing documents yesterday."))
        run(Case("you are -> UAR (only common words)",
                 "Tell me whether you are ready to move forward with the offer.",
                 "Tell me whether UAR ready to move forward with the offer."))
        run(Case("I see you -> ICU (spelled-out look-alike made of everyday words)",
                 "The nurse said I see you in the ICU waiting room right now.",
                 "The nurse said ICU in the ICU waiting room right now."))
        run(Case("see eye oh -> CIO (no distinctive letter names)",
                 "Please forward this to the see eye oh of the bank directly.",
                 "Please forward this to the CIO of the bank directly."))
        run(Case("mortgage broker -> mortgagebroker (lowercase non-word is a typo)",
                 "Please call my mortgage broker about the pre approval letter.",
                 "Please call my mortgagebroker about the pre approval letter."))
        run(Case("Fannie Mae -> Freddie Mac (name to different name)",
                 "This loan was sold to Fannie Mae after closing last month.",
                 "This loan was sold to Freddie Mac after closing last month."))
        run(Case("Jon -> John (capitalized name to capitalized name)",
                 "I am meeting Jon at the title company this afternoon.",
                 "I am meeting John at the title company this afternoon."))
        run(Case("Smyth -> Smith at the start of a sentence (a capital proves nothing there)",
                 "Smyth called about the appraisal and wants a callback today.",
                 "Smith called about the appraisal and wants a callback today."))
        run(Case("Ernest -> Earnest at the start of a sentence (could be a name swap: learn nothing)",
                 "Ernest money is due within three days of acceptance by the buyer.",
                 "Earnest money is due within three days of acceptance by the buyer."))
        run(Case("Patel -> rate (a name replaced by a loosely similar everyday word)",
                 "Please ask Patel about the points before we lock this loan today.",
                 "Please ask rate about the points before we lock this loan today."))
        run(Case("Ploomer -> plan offer (one nonsense word rewritten as two everyday words, weak match)",
                 "Please review the Ploomer before we lock this loan today.",
                 "Please review the plan offer before we lock this loan today."))
        run(Case("federal housing administration -> FHA (an abbreviation, not a mishearing)",
                 "This is a federal housing administration loan with low down payment.",
                 "This is a FHA loan with low down payment."))
        run(Case("heard side of four words is too big",
                 "We offer he is a lock here for you and the rest of the clients today.",
                 "We offer HELOC here for you and the rest of the clients today."))
        run(Case("a 3-word rewrite into 3 different words",
                 "The borrower will sign tomorrow morning at the title office downtown.",
                 "The borrower will sign tomorrow morning at the escrow branch downtown."))
        run(Case("short acronym swapped for a different acronym: FHA -> VA",
                 "This is an FHA loan with a low down payment for first time buyers.",
                 "This is a VA loan with a low down payment for first time buyers."))
        run(Case("Nicholson -> Zhangg: similarity alone must reject (written side is a non-word)",
                 "Please send the signed disclosures to Daniel Nicholson before noon.",
                 "Please send the signed disclosures to Daniel Zhangg before noon."))
        run(Case("Sarah -> Jessika: similarity alone must reject",
                 "I will have Sarah call you back this afternoon about the appraisal.",
                 "I will have Jessika call you back this afternoon about the appraisal."))
        run(Case("snapshot taken mid-typing: Helllock -> HEL",
                 "We can finance the renovation through a Helllock on your primary home.",
                 "We can finance the renovation through a HEL on your primary home."))
        run(Case("article typed in front of the fix: Helllock -> a HELOC",
                 "We can finance the renovation through Helllock on your primary home.",
                 "We can finance the renovation through a HELOC on your primary home."))
        run(Case("fix followed by an e-mail address typed right after it",
                 "We can finance the renovation through a Helllock on your primary home.",
                 "We can finance the renovation through a HELOC alex@lender.example.com on your primary home."))
        run(Case("shouting: Softwear -> SOFTWARE",
                 "Our Softwear will send you the disclosures automatically this week.",
                 "Our SOFTWARE will send you the disclosures automatically this week."))
        run(Case("shouting a real word: Helllo -> HELLO",
                 "Our team says Helllo to every new client who calls the office.",
                 "Our team says HELLO to every new client who calls the office."))
        run(Case("I owe you -> IOU (an abbreviation, not a mishearing)",
                 "Tell Maria that I owe you the signed note by Friday.",
                 "Tell Maria that IOU the signed note by Friday."))
        run(Case("typo introduced while editing: Fanny May -> Fanni",
                 "This product follows the standard Fanny May guidelines for conforming loans.",
                 "This product follows the standard Fanni guidelines for conforming loans."))
        run(Case("one word split in two by the user: Helllock -> HELOC loan (second word is new)",
                 "We can finance the renovation through a Helllock soon.",
                 "We can finance the renovation through a HELOC loan soon.",
                 [("Helllock", "HELOC")]))
        run(Case("3-letter acronyms one letter apart are different things (VOE -> VOD)",
                 "We still need the VOE from the borrower's employer before closing.",
                 "We still need the VOD from the borrower's employer before closing."))
        run(Case("3-letter acronym one letter off: DTE -> DTI (too ambiguous, DTE is also a company)",
                 "Your DTE ratio is slightly above the program limit for this loan.",
                 "Your DTI ratio is slightly above the program limit for this loan."))
        run(Case("longer acronym one letter off: FHLMC -> FHLMA",
                 "The loan was sold to FHLMC after the closing last month.",
                 "The loan was sold to FHLMA after the closing last month.",
                 [("FHLMC", "FHLMA")]))

        // ---------------------------------------------------------------------------------
        section("8. robustness")
        let big = Array(repeating: "mortgage", count: 3000).joined(separator: " ")
        let t0 = Date()
        let bigResult = EditLearner.corrections(pasted: big, edited: big + " Helllock")
        fact("huge input returns quickly and learns nothing", bigResult.isEmpty && Date().timeIntervalSince(t0) < 2.0)
        let t1 = Date()
        var timed = 0
        for _ in 0..<20 { timed += EditLearner.corrections(pasted: long80, edited: long80.replacingOccurrences(of: "Helllock", with: "HELOC")).count }
        let perCall = Date().timeIntervalSince(t1) / 20
        fact("80-word paste with a fix takes < 50 ms per call (\(String(format: "%.1f", perCall * 1000)) ms)", timed == 20 && perCall < 0.05)
        run(Case("emoji and non-Latin text do not crash", "Great 🎉 news about the loan 日本語 today.", "Great 🎉 news about the loan 日本語 tomorrow."))
        run(Case("only whitespace differences", "A  Helllock \n is fine.", "A Helllock is fine."))
        var offMain: [EditLearner.Correction] = [EditLearner.Correction(heard: "x", written: "y")]
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            offMain = EditLearner.corrections(pasted: "a Helllock b", edited: "a HELOC b")
            sem.signal()
        }
        sem.wait()
        fact("called off the main thread: returns [] instead of crashing", offMain.isEmpty)

        // ---------------------------------------------------------------------------------
        print("\n\(passed + failed) checks: \(passed) passed, \(failed) failed")
        print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
