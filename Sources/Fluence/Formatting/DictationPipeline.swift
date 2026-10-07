import FluenceCore
import Foundation
import MurmurDictionary

/// From the engine's transcript to the text that gets typed (FLU-5 text).
///
/// 1. **Snippets.** A dictation that *is* a trigger becomes its expansion, untouched. A
///    trigger inside a dictation is swapped for a placeholder (⟦1⟧) so nothing below can
///    change the expansion.
/// 2. **Language.** The chosen language, or in Auto the one detected in this transcript.
/// 3. **Cleanup** at the chosen level: none, rules, rules + model, rules + model + style.
/// 4. **Dictionary**, always — it is the guaranteed half of the dictionary and must not be
///    something a level can switch off.
/// 5. **Expansions** go back in, verbatim.
@MainActor
enum DictationPipeline {
    struct Output {
        let text: String
        let corrections: [AppliedCorrection]
        /// How many snippets fired — a count for the log, never which ones.
        let snippetCount: Int
    }

    /// - Parameters:
    ///   - category: where the text is going; only level High uses it.
    ///   - bundleID: the app the text is going into, for Clement's developer formatting.
    ///   - formatter: a formatter injected by tests, used instead of the level's own.
    static func process(
        _ raw: String,
        category: AppCategory,
        bundleID: String? = nil,
        formatter: (any TextFormatter)? = nil
    ) async -> Output {
        let settings = Settings.shared
        let snippets = SnippetStore.shared.active
        let developer = settings.appAwareStylesEnabled && DeveloperTools.contains(bundleID: bundleID)

        if let whole = SnippetMatcher.wholeUtterance(raw, snippets: snippets) {
            return Output(text: whole.expansion, corrections: [], snippetCount: 1)
        }

        let (shielded, expansions) = SnippetMatcher.protect(raw, snippets: snippets)
        let language = DictationLanguage.detect(
            shielded,
            selected: settings.dictationLanguage,
            fallback: DictationLanguage(locale: Locale.current) ?? .english
        )

        let level = settings.effectiveCleanupLevel
        var cleaned: String
        if let formatter {
            cleaned = await formatter.format(shielded)
        } else {
            switch level {
            case .none:
                cleaned = shielded.trimmingCharacters(in: .whitespacesAndNewlines)
            case .light:
                // Clement's repairs (stutters, "scratch that", self-corrections) around the
                // tested rules.
                cleaned = RuleCleanup.apply(SpeechRepairs.before(shielded, language: language), language: language)
            case .medium, .high:
                let style = level.appliesStyle
                    ? CleanupPrompt.Style(style: settings.style(for: category), category: category)
                    : nil
                cleaned = await FoundationModelFormatter(
                    language: language,
                    style: style,
                    placeholderCount: expansions.count
                ).format(shielded)
            }
        }

        if level != .none {
            cleaned = SpeechRepairs.after(cleaned, language: language, developer: developer)
        }

        let corrector = DictionaryStore.shared.corrector
        let (corrected, corrections) = corrector.apply(to: cleaned)

        if let restored = SnippetMatcher.restore(corrected, expansions: expansions) {
            return Output(text: restored, corrections: corrections, snippetCount: expansions.count)
        }

        // Only an injected formatter can get here — every built-in level keeps placeholders
        // or falls back to the rules, which do. Redo it with the rules rather than type a
        // placeholder or lose a snippet.
        Log.speech.info("snippet placeholders lost in cleanup — redoing it with the rules")
        let ruled = corrector.apply(to: RuleCleanup.apply(shielded, language: language))
        let text = SnippetMatcher.restore(ruled.text, expansions: expansions) ?? ruled.text
        return Output(text: text, corrections: ruled.applied, snippetCount: expansions.count)
    }
}
