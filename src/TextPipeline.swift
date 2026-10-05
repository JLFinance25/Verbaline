import Foundation

/// Raw transcript → the text that gets pasted. Shared by the app and `--selftest` so they can't drift apart.
enum TextPipeline {
    struct Result {
        let text: String
        /// Word swaps the dictionary's `heard -> written` lines made (learned or added by hand), for the "Fixed" pill.
        let fixes: [(from: String, to: String)]
    }

    static func finish(_ raw: String, useAI: Bool, cleaner: TextCleaner,
                       dictionary: PersonalDictionary, snippets: Snippets) async -> Result {
        guard !raw.isEmpty else { return Result(text: "", fixes: []) }
        // Snippets and spoken formatting are exact by design. The AI could reword a trigger phrase or
        // merge lines, so a dictation that uses either gets the rule cleanup only.
        let exact = snippets.containsTrigger(raw) || SpokenFormatting.containsCommand(raw)
        let cleaned = await cleaner.clean(raw, useLLM: useAI && !exact)
        let marked = snippets.mark(cleaned)                      // triggers → placeholders nothing else touches
        let spelled = dictionary.applyReporting(to: marked.text)
        let formatted = SpokenFormatting.apply(spelled.text)
        return Result(text: snippets.fill(formatted, marked.expansions), fixes: spelled.swaps)
    }
}
