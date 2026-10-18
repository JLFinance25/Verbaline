// meeting_summarizer_test.swift
// Tests MeetingSummarizer + MeetingStore on a made-up mortgage meeting (fictional people and numbers).
//   1. Checks (no model): number reading, loan-detail and to-do guards, splitting into pieces, picking
//      relevant parts for a question.
//   2. MeetingStore: Markdown save → load round-trip, newest-first list, safe file names.
//   3. The on-device model: overview not empty, to-dos with owners, every loan-detail number in the transcript,
//      loan details off → none, a ~60-minute meeting summarised without error, a question that's answered and
//      one that isn't. Skipped (and reported) if Apple Intelligence isn't available.
// Build: swiftc -parse-as-library src/MeetingTypes.swift src/MeetingSummarizer.swift tests/meeting_summarizer_test.swift
// Usage: meeting_summarizer_test [--skip-model] [--quick]   (--quick skips the ~90 s 60-minute meeting)

import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)\(detail().isEmpty ? "" : " — " + detail())") }
}

typealias C = MeetingSummarizer.Checks

// A first-time buyer pre-approval meeting. Everyone and every number here is made up.
let script: [(Speaker, String)] = [
    (.you, "Hi Maria, hi Daniel, thanks for making time today. Can you both hear me okay?"),
    (.them, "Yes, we can hear you. This is Maria, and Daniel is here with me too."),
    (.you, "Great. So the goal for this meeting is to get you pre-approved so you can start making offers. Tell me a little about what you're looking for."),
    (.them, "We're first-time buyers. We've been renting in Riverside for about six years and we want a three bedroom house near Daniel's work."),
    (.you, "Okay, and do you have a price range in mind?"),
    (.them, "We've been looking at homes around $425,000. Some are a bit more, but we'd like to stay at $425,000 or under."),
    (.you, "That's helpful. How much are you planning to put down?"),
    (.them, "We've saved $85,000 for the down payment, so that's 20%. We also have some extra set aside for closing costs."),
    (.you, "Perfect. With $85,000 down on $425,000, the loan amount would be $340,000. Twenty percent down also means no mortgage insurance."),
    (.them, "Oh, that's good to know. We weren't sure about that."),
    (.you, "Let's talk about income. What do you each do for work?"),
    (.them, "I'm a nurse at the county hospital, I make about $78,000 a year. Daniel is an electrician."),
    (.them, "Yeah, I'm salaried, $54,000 a year, plus some overtime, but the overtime changes a lot."),
    (.you, "So that's $132,000 a year combined without the overtime. We'll leave the overtime out for now to be safe."),
    (.them, "That makes sense."),
    (.you, "Any monthly debts? Car payments, student loans, credit cards?"),
    (.them, "One car payment, $410 a month, and Maria has a student loan, about $220 a month."),
    (.you, "Okay. Those are both pretty manageable compared to your income."),
    (.them, "What kind of rate should we expect right now?"),
    (.you, "Rates move every day, so I can't promise anything until we lock. Today a 30-year fixed for someone in your situation is quoting around 6.375%, but that's just today's quote, not a lock."),
    (.them, "Okay. And when would we lock the rate?"),
    (.you, "Usually once you have an accepted offer. We can talk about the options then."),
    (.them, "Our lease ends at the end of January, so we'd love to close by mid-January if we can."),
    (.you, "That's very doable. Most closings take about 30 to 45 days from an accepted offer, so if you find something in November you're in good shape."),
    (.you, "Here's what I need from you to get the pre-approval done. Your two most recent pay stubs each, your W-2s for 2024 and 2025, and two months of bank statements for every account."),
    (.them, "Can we upload those through the portal you emailed?"),
    (.you, "Yes, the secure portal is the easiest way. And I'll need permission to pull credit for both of you."),
    (.them, "Sure, that's fine. We'll upload everything this weekend."),
    (.you, "Great. Once I have the documents, I'll run credit and send you the pre-approval letter, usually within a day or two."),
    (.them, "Should we tell our real estate agent anything?"),
    (.you, "Yes, I'll send your agent, Priya, a quick note introducing myself so she knows the pre-approval is in progress."),
    (.them, "Thank you. Priya will appreciate that."),
    (.you, "Let's set up a follow-up meeting to go over the letter and any questions. How's Thursday, October 23rd at 3 pm?"),
    (.them, "Thursday the 23rd at 3 works for both of us."),
    (.you, "Perfect, I'll send an invite. Anything else on your mind?"),
    (.them, "Just one thing, Daniel wants to know if we should pay off the car first."),
    (.you, "Let's not move any money around until after closing. Keep everything as it is for now, and don't open any new credit cards."),
    (.them, "Got it. No new credit cards."),
    (.you, "Great. Thanks again, both of you, talk Thursday."),
    (.them, "Thanks so much, bye."),
]

func lines(offset: TimeInterval = 0, variant: Int = 0) -> [TranscriptLine] {
    var t = offset
    return script.map { s, text in
        defer { t += Double(max(3, C.wordCount(text) / 2)) }
        return TranscriptLine(speaker: s, start: t.rounded(.down), text: text)
    }
}

// MARK: 1. Checks

func checksTests() {
    let n = C.numbers(in: "Around $425,000, 20% down, 450k, 1.2 million, 6.375%, ninety thousand, the 23rd, two pay stubs")
    check(n.contains(425000) && n.contains(20) && n.contains(450000) && n.contains(1_200_000) && n.contains(6.375)
          && n.contains(90000) && n.contains(23) && n.contains(2), "numbers: digits, k/million, words", "\(n)")
    let known = C.knownNumbers(in: C.render(lines()))
    check(C.unknownNumbers(in: "Purchase price $425k with 20% down", known: known).isEmpty, "number guard: $425k matches $425,000")
    check(!C.unknownNumbers(in: "a rate of 6.5%", known: known).isEmpty, "number guard: invented 6.5% caught")
    let text = C.render(lines())
    check(C.acceptLoanValue("$425,000", needsNumber: true, known: known, transcript: text) == "$425,000", "loan value: real price kept")
    check(C.acceptLoanValue("$440,000", needsNumber: true, known: known, transcript: text) == nil, "loan value: invented price dropped")
    check(C.acceptLoanValue("Not mentioned", needsNumber: true, known: known, transcript: text) == nil, "loan value: 'not mentioned' dropped")
    check(C.acceptLoanValue("pre-approval letter", needsNumber: true, known: known, transcript: text) == nil, "loan value: rate without a number dropped")
    check(C.acceptLoanValue("Refinance to lower their payment on a vacation condo", needsNumber: false, known: known, transcript: text) == nil,
          "loan value: made-up purpose dropped")
    check(C.acceptTodo("You will send the pre-approval letter.", known: known) == "Send the pre-approval letter", "to-do: lead-in trimmed")
    check(C.acceptTodo("Upload 7 bank statements", known: known) == nil, "to-do: invented number dropped")
    let (todos, droppedTodos) = C.parseTodos("1. **You:** Send the pre-approval letter\n- Them: Upload pay stubs\nThem: Send 7 statements\nNone", known: known)
    check(todos == [MeetingTodo(owner: .you, task: "Send the pre-approval letter"), MeetingTodo(owner: .them, task: "Upload pay stubs")] && droppedTodos == 1,
          "to-dos: 'You:/Them:' lines read, bullets stripped, invented number dropped", "\(todos) \(droppedTodos)")
    let (leak, _) = C.parseTodos("Them: Upload pay stubs", known: known, transcript: "You: Thanks for joining.\nThem: Happy to, see you next week.")
    check(leak.isEmpty, "to-dos: a task never said in the meeting is dropped")
    let (loan, droppedLoan) = C.parseLoanDetails("**Purchase price:** $425,000\nRate: not said\nLoan amount: $360,000\nShoe size: 9\nDown payment: $85,000 (20%)",
                                                 known: known, transcript: text)
    check(loan.map { $0.0 } == ["purchasePrice", "downPayment"] && droppedLoan == 2, "loan details: known labels read, empty and invented values dropped", "\(loan) \(droppedLoan)")
    check(C.dropUnfinishedEnding("They close in January. The rate is 6.75") == "They close in January." && C.dropUnfinishedEnding("The rate is 6.75") == "The rate is 6.75"
          && C.dropUnfinishedEnding("The rate is 6.75%. Then they") == "The rate is 6.75%.",
          "overview: a decimal point isn't a sentence end (6.75 stays whole)", C.dropUnfinishedEnding("They close in January. The rate is 6.75"))
    let verbs = "I'll call you Monday, and Priya will give them a call."
    check(C.meetingNotCall(verbs) == verbs, "wording: the verb 'call' is left alone", C.meetingNotCall(verbs))
    check(C.meetingNotCall("On the call, and in this phone call, both calls went well.") == "On the meeting, and in this meeting, both meetings went well.",
          "wording: the noun 'call' becomes 'meeting'", C.meetingNotCall("On the call, and in this phone call, both calls went well."))
    check(C.cleanOverview("Here's the overview: Maria and Daniel met with you.") == "Maria and Daniel met with you.", "lead-in: text after 'Here's the overview:' kept")
    check(C.cleanOverview("Here is the overview:\nMaria and Daniel met with you.") == "Maria and Daniel met with you.", "lead-in: a lead-in line on its own is dropped")
    check(C.cleanOverview("Overview\nMaria met with you.") == "Maria met with you.", "lead-in: a bare 'Overview' heading is dropped")
    check(C.cleanTitle("Title: Rate review", fallback: "x") == "Rate review" && C.cleanTitle("Title insurance questions", fallback: "x") == "Title insurance questions"
          && C.cleanTitle("Pre-approval call", fallback: "x") == "Pre-approval meeting",
          "title: only a 'Title:' label is stripped; 'Title insurance' kept", C.cleanTitle("Title insurance questions", fallback: "x"))
    check(C.dropUnfinishedEnding("They plan to close in January.\n\nYou explained that rates move every day and") == "They plan to close in January.",
          "overview: unfinished last sentence cut")
    let (o, d) = C.dropSentencesWithUnknownNumbers("They want to buy at $425,000. The rate is 5.9%. They'll upload documents.", known: known)
    check(d == 1 && !o.contains("5.9") && o.contains("425,000"), "overview: sentence with invented number removed", o)
    let big = (0..<12).flatMap { lines(offset: Double($0) * 300) }
    let p = C.pieces(big, maxWords: MeetingSummarizer.wordsPerPiece)
    check(p.count > 1 && p.allSatisfy { $0.reduce(0) { $0 + C.wordCount($1.text) + 1 } <= MeetingSummarizer.wordsPerPiece }
          && p.flatMap { $0 } == big, "pieces: within budget, nothing lost", "\(p.count) pieces")
    let picked = C.relevantLines(for: "What did they say about the car payment?", in: big, maxWords: 300)
    check(picked.contains { $0.text.contains("$410") }, "relevance: picks the part that mentions the car payment")
    let w = C.cleanOverview("Here is the overview:\nIn this call you discussed rates.")
    check(w == "In this meeting you discussed rates.", "wording: 'call' becomes 'meeting', no 'Here is'", w)
    qualityChecks(known: known, text: text)
}

// The five problems measured on 2026-10-17 (end-to-end test + 60-minute meeting), each with the text the model
// really wrote then.
func qualityChecks(known: Set<Double>, text: String) {
    // 1. Title: a short topic, never a sentence cut off at 8 words.
    check(C.cleanTitle("Maria and I had a meeting today to", fallback: "") == "", "title: a cut-off sentence is rejected",
          C.cleanTitle("Maria and I had a meeting today to", fallback: ""))
    check(C.isTopicTitle("Purchase pre-approval") && C.isTopicTitle("First-time buyers pre-approval meeting")
          && !C.isTopicTitle("You discussed the pre-approval") && !C.isTopicTitle("Rates, documents, and next steps for the"),
          "title: topic titles pass, sentences and cut-offs don't")
    check(C.topicTitle(transcript: text) == "Purchase pre-approval", "title: topic fallback for a pre-approval meeting", C.topicTitle(transcript: text))
    check(C.topicTitle(transcript: "You: What price range are you looking at for the new house?") == "Home purchase planning",
          "title: topic fallback for a purchase meeting")

    // 2. To-dos: the owner is whoever does it; wishes aren't to-dos; short actions.
    let e2e = "You: Hi Maria, thanks for making time today.\nYou: What price range are you looking at for the new house?\nThem: We are hoping to stay under 425,000, and we have saved about 85,000 for the down payment.\nYou: That works. Please send me your last two pay stubs and your W-2s by Friday, and I will send you the document checklist tonight.\nThem: Sounds good, we would like to close by the middle of January if possible."
    let (t2, _) = C.parseTodos("You: Send me your last two pay stubs and your W-2s by Friday\nThem: Sounds good, we would like to close by the middle of January if possible\nYou: Send the document checklist tonight",
                               known: C.knownNumbers(in: e2e), transcript: e2e)
    check(t2 == [MeetingTodo(owner: .them, task: "Send last two pay stubs and W-2s by Friday"), MeetingTodo(owner: .you, task: "Send the document checklist tonight")],
          "to-dos: 'send me your pay stubs' is Them's; 'we'd like to close by January' isn't a to-do", "\(t2)")
    let (labels, _) = C.parseTodos("Loan officer: Send the pre-approval letter\nClients: Send your W-2s for 2024 and 2025", known: known, transcript: text)
    check(labels == [MeetingTodo(owner: .you, task: "Send the pre-approval letter"), MeetingTodo(owner: .them, task: "Send their W-2s for 2024 and 2025")],
          "to-dos: 'Loan officer:' / 'Clients:' labels read", "\(labels)")
    let (made, _) = C.parseTodos("Clients: Send car payment\nClients: Upload documents", known: known, transcript: text)
    let (neg, _) = C.parseTodos("Clients: Send new credit cards\nClients: Open new credit cards", known: known, transcript: text)
    check(neg.isEmpty, "to-dos: 'don't open any new credit cards' never becomes a to-do", "\(neg)")
    check(made == [MeetingTodo(owner: .them, task: "Upload documents")], "to-dos: a task made up from a plain fact ('one car payment') is dropped", "\(made)")
    let (both, _) = C.parseTodos("You: Send the document checklist tonight\nThem: Send the document checklist tonight", known: C.knownNumbers(in: e2e), transcript: e2e)
    check(C.dedupe(both) == [MeetingTodo(owner: .you, task: "Send the document checklist tonight")], "to-dos: owner taken from 'I will send you…', so one task isn't listed twice", "\(both)")
    check(!C.dropUnbackedSentences("The rate of 6.375% is a good rate for them.", lines: C.spokenLines(lines())).0.contains("good rate"), "wording: an unsaid 'good rate' is dropped")
    let (merged, m) = C.dropRepeatedSentences("You need permission to pull credit for both of them.\n\nYou would need permission to pull their credit, and you will send the pre-approval letter within a day or two.")
    check(m == 1 && merged.hasPrefix("You would need permission") && merged.components(separatedBy: "permission").count == 2, "repeats: a sentence said again with more detail keeps only the fuller one", merged)
    check(C.source(of: "Send pre-approval letter", in: text).owner == .you, "to-dos: 'I'll run credit and send you the letter' is a You task")
    check(C.dedupe([MeetingTodo(owner: .them, task: "Send pay stubs"), MeetingTodo(owner: .them, task: "Upload pay stubs and W-2s"),
                    MeetingTodo(owner: .them, task: "Send bank statements")])
          == [MeetingTodo(owner: .them, task: "Upload pay stubs and W-2s"), MeetingTodo(owner: .them, task: "Send bank statements")],
          "to-dos: 'Send pay stubs' and 'Upload pay stubs and W-2s' are one task, the fuller kept")
    check(C.fixTodo(owner: .you, task: "Upload the pay stubs and W-2s")?.0 == .them && C.fixTodo(owner: .you, task: "Send the pre-approval letter")?.0 == .you
          && C.fixTodo(owner: .you, task: "Send pay stubs to underwriting")?.0 == .you,
          "to-dos: client documents are Them's to send; the officer's own sends stay You's")
    check(C.fixTodo(owner: .them, task: "Please send me the document checklist").map { "\($0.0): \($0.1)" } == "you: Send them the document checklist",
          "to-dos: a client asking 'send me the checklist' is a You task", C.fixTodo(owner: .them, task: "Please send me the document checklist").map { $0.1 } ?? "nil")

    // 3. Overview in house style: "you", never "I".
    let firstPerson = "Maria and I had a meeting today to discuss her new house purchase. I asked her to send me her last two pay stubs by Friday, and I will send her the document checklist tonight."
    let fixed = C.secondPerson(firstPerson)
    check(fixed == "You and Maria had a meeting today to discuss her new house purchase. You asked her to send you her last two pay stubs by Friday, and you will send her the document checklist tonight."
          && !C.hasFirstPerson(fixed), "overview: 'Maria and I…' becomes 'You and Maria…'", fixed)
    let quoted = "Maria said \"we want to close by January\" and you agreed."
    check(C.secondPerson(quoted) == quoted && !C.hasFirstPerson(quoted), "overview: quoted words are left as said", C.secondPerson(quoted))
    check(C.capitalizeSentences("the rate is 6.375%. you'll call back.") == "The rate is 6.375%. You'll call back.", "overview: sentence starts capitalised, decimals left alone")

    // 4. Repeats: the 60-minute overview had the same opening sentence in four paragraphs.
    let repeated = "You discussed the pre-approval process with Maria and Daniel. They have saved $85,000.\n\nYou discussed the pre-approval process with Maria and Daniel. You explained that rates move every day.\n\nYou discussed the pre-approval process for Maria and Daniel, who are first-time buyers. Maria and Daniel have saved $85,000 for the down payment."
    let (once, n) = C.dropRepeatedSentences(repeated)
    check(n == 2 && once.components(separatedBy: "pre-approval process").count == 2 && once.contains("rates move every day") && once.contains("first-time"),
          "overview: a repeated sentence is said once, new facts kept", "\(n): \(once)")
    check(!C.sameSentence("They have a car payment of $410 a month.", "Maria has a student loan of $220 a month."), "repeats: different facts aren't repeats")
    check(C.sameSentence("They have a car payment of $410 a month and a student loan of $220 a month.",
                         "They also have a $410 monthly car payment and a $220 monthly student loan."), "repeats: same numbers, other words, is a repeat")
    let officer = C.secondPerson("The loan officer explained that the loan officer's portal is secure. The loan officer is sending the letter.")
    check(officer == "You explained that your portal is secure. You are sending the letter.", "overview: 'The loan officer explained' becomes 'You explained'", officer)

    // 5. Wording drift on regulated words: keep what was said.
    let said = C.spokenLines(lines())
    let drift = "You explained that with their income and down payment, they would qualify for a loan amount of $340,000. The loan amount would be $340,000. They want to get pre-approved so they can make offers. They are pre-approved for $340,000."
    let (kept, droppedClaims) = C.dropUnbackedSentences(drift, lines: said)
    check(droppedClaims == 2 && !kept.contains("qualify") && kept.contains("The loan amount would be $340,000.") && kept.contains("get pre-approved"),
          "wording: 'would qualify for $340,000' and 'pre-approved for $340,000' dropped, the officer's words kept", "\(droppedClaims): \(kept)")
    check(C.acceptLoanValue("Qualifies for $340,000", needsNumber: true, known: known, transcript: text) == nil, "loan value: an unsaid 'qualifies' is dropped")
}

/// Model-output checks shared by the sample and the 60-minute meeting.
func checkWording(_ note: MeetingNote, _ lines: [TranscriptLine], _ label: String) {
    check(C.isTopicTitle(note.title), "\(label): title is a short topic", note.title)
    check(!C.hasFirstPerson(note.overview), "\(label): overview says 'you', never 'I' or 'we'")
    let claims = C.sentences(note.overview).filter { !C.unbackedClaims(in: $0, lines: C.spokenLines(lines)).isEmpty }
    check(claims.isEmpty, "\(label): no qualify/approve/lock claim the meeting didn't make", "\(claims)")
    let ss = C.sentences(note.overview)
    let repeats = ss.indices.flatMap { i in ss.indices.filter { $0 > i && C.sameSentence(ss[i], ss[$0]) }.map { "\(ss[i]) ≈ \(ss[$0])" } }
    check(repeats.isEmpty, "\(label): no sentence repeated", "\(repeats)")
    check(note.todos.allSatisfy { C.wordCount($0.task) <= 16 }, "\(label): to-dos are short actions", "\(note.todos.map(\.task))")
    check(!note.todos.contains { $0.owner == .you && $0.task.lowercased().range(of: "^(send|upload|provide|submit).*(pay stub|w-2|bank statement)", options: .regularExpression) != nil },
          "\(label): sending pay stubs / W-2s / statements isn't a You to-do")
    check(!note.todos.contains { $0.task.lowercased().contains("would like") || $0.task.lowercased().hasPrefix("close") }, "\(label): a wish to close isn't a to-do")
    check(!note.todos.contains { $0.task.lowercased().contains("credit card") || $0.task.lowercased().contains("pay off") },
          "\(label): 'don't open new credit cards' / 'don't pay off the car' aren't to-dos", "\(note.todos.map(\.task))")
    check(!note.todos.contains { $0.owner == .them && $0.task.lowercased().contains("pre-approval letter") }, "\(label): sending the pre-approval letter isn't a Them to-do")
    check(!note.todos.contains { $0.task.lowercased().contains("car payment") || $0.task.lowercased().contains("student loan") }, "\(label): no to-do made up from a debt that was only mentioned")
}

// MARK: 2. MeetingStore

func storeTests() {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("verbaline-notes-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = MeetingStore(folder: tmp)
    let date = ISO8601DateFormatter().date(from: "2026-10-17T14:02:31Z")!
    let note = MeetingNote(title: "Purchase pre-approval: Alvarez / first home", date: date, duration: 1923.5, appName: "FaceTime",
                           overview: "You met with Maria and Daniel.\n\nThey want to buy at $425,000.\n# not a heading",
                           todos: [MeetingTodo(owner: .you, task: "Send the pre-approval letter"), MeetingTodo(owner: .them, task: "Upload pay stubs")],
                           loanDetails: [.init(label: "Purchase price", value: "$425,000"), .init(label: "Follow-up date", value: "Thursday, October 23rd at 3 pm")],
                           transcript: lines())
    guard let url = try? store.save(note) else { check(false, "store: save"); return }
    check(url.lastPathComponent.hasPrefix(MeetingStoreTestStamp(date)) && !url.lastPathComponent.contains("/") && url.pathExtension == "md",
          "store: file name like '2026-10-17 1402 <title>.md'", url.lastPathComponent)
    let back = store.load(url)
    check(back == note, "store: Markdown round-trip gives the same note",
          back.map { "title=\($0.title) dur=\($0.duration) todos=\($0.todos.count) loan=\($0.loanDetails.count) lines=\($0.transcript.count) overview=\($0.overview.debugDescription)" } ?? "nil")
    let md = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let order = ["# Purchase", "- Date:", "- Length:", "- App:", "## Overview", "## To do", "## Loan details", "## Transcript", "[00:00] You:"]
    let idx = order.map { md.range(of: $0)?.lowerBound }
    check(idx.allSatisfy { $0 != nil } && zip(idx, idx.dropFirst()).allSatisfy { $0! < $1! }, "store: sections in order (title, date, length, app, overview, to do, loan details, transcript)")
    var older = note; older.date = date.addingTimeInterval(-86400); older.title = "Refinance review"
    var newer = note; newer.date = date.addingTimeInterval(3600); newer.title = "Rate lock follow-up"
    _ = try? store.save(older); _ = try? store.save(newer)
    let again = try? store.save(note)
    let names = store.list().map { $0.lastPathComponent }
    check(names.count == 4 && names.first!.contains("Rate lock") && names.last!.contains("Refinance"), "store: list() newest first", "\(names)")
    check(again != url, "store: same name twice doesn't overwrite")
    var noLoan = note; noLoan.loanDetails = []; noLoan.todos = []
    check(MeetingStore.parse(MeetingStore.markdown(noLoan)) == noLoan, "store: round-trip with no to-dos and no loan details")
    let gapped = MeetingStore.markdown(noLoan, gaps: [.todos, .loanDetails])
    check(gapped.components(separatedBy: MeetingSummarizer.Gaps.incompleteNote).count == 3 && !gapped.contains("_No to-dos._") && !gapped.contains("_None._")
          && MeetingStore.parse(gapped) == noLoan, "store: failed parts say 'may be incomplete', not 'No to-dos'")
    let blocker = tmp.appendingPathComponent("not-a-folder")
    try? "x".write(to: blocker, atomically: true, encoding: .utf8)
    check((try? MeetingStore(folder: blocker.appendingPathComponent("notes")).save(note)) == nil, "store: save throws when it can't write")
}

func MeetingStoreTestStamp(_ d: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HHmm"; return f.string(from: d)
}

// MARK: 3. The model

@main struct Main {
    static func main() async {
        checksTests()
        storeTests()
        if CommandLine.arguments.contains("--skip-model") { finish(); return }
        let s = MeetingSummarizer()
        guard s.isAvailable else { print("SKIP  model tests: Apple Intelligence not available (model unavailable)"); finish(); return }
        let sample = lines()
        let transcript = C.render(sample)
        let known = C.knownNumbers(in: transcript)
        print("sample: \(sample.count) lines, \(C.wordCount(transcript)) words")

        var t0 = Date()
        let note = await s.summarize(sample, appName: "FaceTime", date: Date(), duration: 600, loanDetails: true)
        print(String(format: "summarize: %.1f s (%@)", Date().timeIntervalSince(t0), s.lastDiagnostic))
        print("---- title: \(note.title)\n---- overview (\(C.wordCount(note.overview)) words):\n\(note.overview)")
        print("---- to-dos:"); note.todos.forEach { print("  \($0.owner): \($0.task)") }
        print("---- loan details:"); note.loanDetails.forEach { print("  \($0.label): \($0.value)") }
        check(C.wordCount(note.overview) >= 60, "overview isn't empty (≥ 60 words)", "\(C.wordCount(note.overview)) words")
        check(!note.title.isEmpty && note.title != "Meeting on FaceTime", "title written", note.title)
        check(!note.todos.isEmpty, "to-dos found")
        check(note.todos.contains { $0.owner == .you } && note.todos.contains { $0.owner == .them }, "to-dos have owners (you and them)")
        check(!note.todos.contains { $0.task.lowercased().contains("pay off") || $0.task.lowercased().contains("credit card") },
              "advice not to do something isn't turned into a to-do")
        check(!note.loanDetails.isEmpty, "loan details found")
        let bad = note.loanDetails.filter { !C.unknownNumbers(in: $0.value, known: known).isEmpty }
        check(bad.isEmpty, "every loan-detail number appears in the transcript", "\(bad)")
        check(C.unknownNumbers(in: note.overview, known: known).isEmpty, "every overview number appears in the transcript")
        check(note.loanDetails.first { $0.label == "Purchase price" }?.value.contains("425") ?? false, "purchase price is $425,000")
        check(!note.overview.lowercased().contains(" call "), "overview says meeting, not call")
        check(note.transcript == sample, "transcript kept unchanged")
        checkWording(note, sample, "sample")
        check(note.todos.contains { $0.owner == .them && $0.task.lowercased().contains("pay stub") || $0.owner == .them && $0.task.lowercased().contains("upload") },
              "sample: uploading the documents is a Them to-do")

        t0 = Date()
        let off = await s.summarize(sample, appName: "Zoom", date: Date(), duration: 600, loanDetails: false)
        check(off.loanDetails.isEmpty, "loan details off → none", String(format: "%.1f s", Date().timeIntervalSince(t0)))
        check(s.lastGaps.isEmpty, "no failed parts on a normal meeting", s.lastDiagnostic)

        let a1 = await s.answer("What purchase price did they mention?", from: sample)
        print("Q1: \(a1)")
        check(a1.contains("425"), "answers a question that's in the transcript", a1)
        let a2 = await s.answer("What is their credit score?", from: sample)
        print("Q2: \(a2)")
        check(a2 == MeetingSummarizer.notFound, "says so when the answer isn't in the transcript", a2)

        if CommandLine.arguments.contains("--quick") { print("SKIP  60-minute meeting (--quick; runs in the full suite)"); finish(); return }

        // ~60 minutes: the meeting 14 times over with times shifted, ~9,000 words (about 150 spoken words a minute).
        let long = (0..<14).flatMap { lines(offset: Double($0) * 257) }
        let longText = C.render(long)
        t0 = Date()
        let longNote = await s.summarize(long, appName: "Zoom", date: Date(), duration: 3600, loanDetails: true)
        let longSecs = Date().timeIntervalSince(t0)
        print(String(format: "60-minute meeting: %d words, %.1f s (%@)", C.wordCount(longText), longSecs, s.lastDiagnostic))
        print("---- long title: \(longNote.title)\n---- long overview:\n\(longNote.overview)")
        print("---- long to-dos:"); longNote.todos.forEach { print("  \($0.owner): \($0.task)") }
        check(!s.lastDiagnostic.contains("failed"), "60-minute meeting summarised without error", s.lastDiagnostic)
        check(C.wordCount(longNote.overview) >= 60, "60-minute overview isn't empty")
        check(".!?".contains(longNote.overview.last ?? " "), "60-minute overview ends with a whole sentence")
        let longKnown = C.knownNumbers(in: longText)
        check(longNote.loanDetails.allSatisfy { C.unknownNumbers(in: $0.value, known: longKnown).isEmpty }, "60-minute loan-detail numbers all in transcript")
        checkWording(longNote, long, "60-minute")
        let longWords = C.wordCount(longNote.overview)
        check((120...600).contains(longWords), "60-minute overview is a 2–3 minute read (120–600 words)", "\(longWords) words")
        let openers = longNote.overview.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.split(separator: " ").prefix(4).joined(separator: " ").lowercased() }
        check(Set(openers).count == openers.count, "60-minute: no two paragraphs start the same way", "\(openers)")

        t0 = Date()
        let a3 = await s.answer("How much is the car payment?", from: long)
        print(String(format: "Q3 on 60 min (%.1f s, %@): %@", Date().timeIntervalSince(t0), s.lastDiagnostic, a3))
        check(a3.contains("410"), "answers from the right part of a 60-minute meeting", a3)
        let a4 = await s.answer("What's the name of the title company?", from: long)
        print("Q4 on 60 min: \(a4)")
        check(a4 == MeetingSummarizer.notFound, "60-minute: says so when the answer isn't there", a4)
        finish()
    }

    static func finish() {
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
