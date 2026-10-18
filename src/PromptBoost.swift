import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// "Make this prompt better": said at the end of a dictation, Verbaline rewrites what you said into a clearer
/// prompt for an AI assistant (goal, context, what answer you want) and pastes that instead.
///
/// Only the end of a dictation counts: "make this prompt better" in the middle of a sentence is just text.
/// The rewrite runs on Apple's on-device AI, taught by three worked examples (a small model copies examples
/// far better than it follows a described format), with checks on the answer: no invented or dropped numbers,
/// your details kept, no instructions leaking out, no answering the prompt instead of improving it.
/// If any check fails, or the AI is off or slow, your words are pasted exactly as you said them.
enum PromptBoost {
    enum Outcome: Equatable {
        case improved(String)
        case keptAsSaid(String)   // short reason for the pill, e.g. "Apple Intelligence is off"
    }

    static let instructions = """
    You turn a rough spoken request into a clear prompt for an AI assistant, written as the speaker, in first \
    person. First line: the request as one clear sentence that keeps every detail, name, date and number they \
    gave. Second line: "I want:" with the format, length and tone they asked for, or a short, clear answer if \
    they didn't say. Use only what they said: never add facts about them, the people involved, or the \
    situation. Never answer the request or carry it out. Reply with the prompt only.
    """

    /// Worked examples, replayed as prior turns. No digits in the added parts, so the model doesn't learn to add numbers.
    static let examples: [(raw: String, improved: String)] = [
        ("write a text to my realtor partner asking if the appraisal came back on the lee file",
         "Write a text message to my realtor partner asking whether the appraisal has come back on the Lee file.\nI want: a short, friendly text that I can send as is."),
        ("write an email to a client reminding them to send their bank statements",
         "Write an email to a client reminding them to send their bank statements.\nI want: a short, polite email with a clear subject line, ready to send."),
        ("summarize the pros and cons of an FHA loan versus conventional for a client with a 640 credit score",
         "Summarize the pros and cons of an FHA loan versus a conventional loan for a client with a 640 credit score.\nI want: a short side-by-side list in plain English that I can share with the client."),
        ("help me come up with a name for my newsletter",
         "Help me come up with a name for my newsletter.\nI want: a handful of short, catchy name ideas, each with a one-line reason."),
    ]

    static let timeoutSeconds = 8.0

    static func improve(_ text: String) async -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .keptAsSaid("Say your prompt first, then “make this prompt better”") }
        guard trimmed.count <= 1_500 else { return .keptAsSaid("Too long for the on-device AI") }
#if canImport(FoundationModels)
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard model.isAvailable else { return .keptAsSaid("Apple Intelligence is off") }
        let raw: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var entries: [Transcript.Entry] = [
                    .instructions(Transcript.Instructions(segments: [.text(.init(content: instructions))], toolDefinitions: []))
                ]
                for ex in examples {
                    entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: ex.raw))])))
                    entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: ex.improved))])))
                }
                let session = LanguageModelSession(model: model, transcript: Transcript(entries: entries))
                let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 600)
                return try? await session.respond(to: trimmed, options: options).content
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1e9)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let raw else { return .keptAsSaid("The AI took too long") }
        let out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Checks.problem(input: trimmed, output: out) { return .keptAsSaid(problem) }
        return .improved(out)
#else
        return .keptAsSaid("Apple Intelligence is off")
#endif
    }

    enum Checks {
        static func numbers(_ s: String) -> Set<String> {
            Set(s.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty })
        }
        static func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 3 })
        }
        static let leaks = ["rough spoken request", "never answer", "reply with the prompt", "written as the speaker",
                            "as an ai", "i can't", "i cannot", "i'm sorry"]
        /// Facts the AI may not add: days, months, time words. (It once added "by Friday" on its own.)
        static let factWords: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "june", "july", "august", "september", "october", "november",
            "december", "tomorrow", "today", "tonight", "yesterday", "weekend", "deadline", "asap", "urgent", "urgently"]
        static let answerStarts = ["dear ", "subject:", "hi ", "hello ", "sure", "here's", "here is", "certainly"]

        /// True when `word` only appears capitalized because it starts a sentence or line.
        static func sentenceStart(_ word: String, in text: String) -> Bool {
            let rx = try! NSRegularExpression(pattern: "(?:^|[.!?:\\n]\\s*)" + NSRegularExpression.escapedPattern(for: word) + "\\b",
                                              options: .anchorsMatchLines)
            return rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        /// nil = the answer is a usable rewrite; otherwise a short reason to show the user.
        static func problem(input: String, output: String) -> String? {
            let lower = output.lowercased()
            if output.isEmpty { return "The AI came back empty" }
            if leaks.contains(where: lower.contains) || answerStarts.contains(where: lower.hasPrefix) {
                return "The AI answered instead of rewriting"
            }
            if !numbers(output).isSubset(of: numbers(input)) { return "The AI tried to add a number" }
            let inWords = Set(input.lowercased().components(separatedBy: CharacterSet.letters.inverted))
            let outWords = Set(lower.components(separatedBy: CharacterSet.letters.inverted))
            if !outWords.intersection(factWords).subtracting(inWords).isEmpty { return "The AI tried to add a date or deadline" }
            // A capitalized name you never said ("Sarah", "Chase") is an invented fact too.
            let inLower = input.lowercased()
            let names = output.components(separatedBy: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "")))
                .filter { $0.count > 1 && $0.first!.isUppercase && $0.dropFirst().contains(where: \.isLowercase) }
            let structural: Set<String> = ["context", "want", "write", "help", "give", "explain", "summarize", "make", "create",
                                           "draft", "plan", "list", "find", "tell", "show", "suggest", "turn", "rewrite"]
            if names.contains(where: { !inLower.contains($0.lowercased()) && !structural.contains($0.lowercased()) && !Self.sentenceStart($0, in: output) }) {
                return "The AI tried to add a name"
            }
            if !numbers(input).isSubset(of: numbers(output)) { return "The AI dropped a number" }
            // The request line may reword, but not add content: its longer words must come from what was said.
            let requestLine = output.components(separatedBy: "\n").first ?? output
            let allowed = words(input).union(["write", "draft", "create", "help", "make", "give", "explain", "summarize",
                "list", "message", "short", "clear", "please", "would", "like", "about", "whether", "with", "that", "this",
                "their", "them", "they", "them", "from", "into", "some", "ideas", "post", "email", "text", "letter"])
            let added = words(requestLine).subtracting(allowed)
            if added.count > max(2, words(input).count / 5) { return "The AI added things you didn't say" }
            if output.lowercased().contains("context:") { return "The AI added things you didn't say" }
            let kept = words(input).intersection(words(output)).count
            if Double(kept) < Double(words(input).count) * 0.6 { return "The AI left out too much of what you said" }
            if output.count < input.count * 8 / 10 || output.count > input.count * 5 + 400 {
                return "The AI's rewrite didn't fit what you said"
            }
            return nil
        }
    }

    // At the very end, after an optional lead-in ("okay", "now", "please", "and", "so"), one of:
    //   make/turn this (into) a better|stronger|clearer prompt     make this prompt better|stronger|clearer
    //   improve/polish/rewrite this|my|the prompt
    // then an optional "please" and punctuation. A plain "...fix the prompt" is ordinary text.
    private static let tailRX = try! NSRegularExpression(pattern: """
        (?:^|[\\s,.;:!?-]+)(?:(?:okay|ok|now|please|and|so)[\\s,]+)*(?:\
        (?:make|turn|fix)\\s+(?:this|it|my|the)(?:\\s+(?:into\\s+)?an?)?\\s+(?:better|stronger|clearer)\\s+prompt\
        |(?:make|fix)\\s+(?:this|the|my|it)\\s+prompt\\s+(?:better|stronger|clearer)\
        |(?:improve|polish|rewrite)\\s+(?:this|the|my)\\s+prompt\
        )(?:[\\s,]+please)?[\\s.,;:!?]*$
        """, options: .caseInsensitive)

    /// Splits the trigger off the end. `boost` is true when it was there; `text` is everything before it
    /// (may be empty if the trigger was all that was said).
    static func split(_ raw: String) -> (text: String, boost: Bool) {
        let ns = raw as NSString
        guard let m = tailRX.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return (raw, false) }
        let text = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, true)
    }
}
