import Foundation

/// Raw transcript → the text that gets pasted. Shared by the app and `--selftest` so they can't drift apart.
enum TextPipeline {
    struct Result {
        let text: String
        /// Word swaps the dictionary's `heard -> written` lines made (learned or added by hand), for the "Fixed" pill.
        let fixes: [(from: String, to: String)]
        /// The dictation ended with "press enter": press Return after inserting `text` (which may be empty).
        var pressEnter = false
    }

    static func finish(_ raw: String, useAI: Bool, cleaner: TextCleaner,
                       dictionary: PersonalDictionary, snippets: Snippets, pressEnterCommand: Bool = false) async -> Result {
        // Taken off before cleanup so the AI can't reword or drop the command.
        let (raw, pressEnter) = pressEnterCommand ? PressEnter.split(raw) : (raw, false)
        guard !raw.isEmpty else { return Result(text: "", fixes: [], pressEnter: pressEnter) }
        // "spell H E L O C" → "HELOC" first, before cleanup can touch the letters.
        let spelled = Spelling.apply(raw)
        // Snippets, spoken formatting and spelled words are exact by design. The AI could reword a trigger
        // phrase, merge lines or "fix" a spelling, so a dictation that uses any of them gets the rule cleanup only.
        let exact = !spelled.words.isEmpty || snippets.containsTrigger(spelled.text)
            || SpokenFormatting.containsCommand(spelled.text)
        let cleaned = await cleaner.clean(spelled.text, useLLM: useAI && !exact)
        let shielded = Spelling.shield(cleaned, spelled.words)   // spelled words → placeholders nothing else touches
        let marked = snippets.mark(shielded.text)                // triggers → placeholders nothing else touches
        let dictionaryFixes = dictionary.applyReporting(to: marked.text)
        let formatted = SpokenFormatting.apply(dictionaryFixes.text)
        let filled = Spelling.unshield(snippets.fill(formatted, marked.expansions), shielded.words)
        return Result(text: filled, fixes: dictionaryFixes.swaps, pressEnter: pressEnter)
    }
}
