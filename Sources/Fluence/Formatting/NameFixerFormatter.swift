import FluenceCore
import Foundation
import FoundationModels

/// Level Medium, and High in French (FLU-91, FLU-92): Light, then Apple's on-device model may
/// only swap a misheard name for the dictionary's spelling. `NameFixer` decides whether the
/// model is worth calling and keeps nothing of its answer but those swaps, so a dictation that
/// reads as a question is never answered. Unavailable, too slow or failing: the Light text.
struct NameFixerFormatter: TextFormatter {
    var language: DictationLanguage = .english
    /// Going into a terminal or a code editor: no French typography (FLU-90).
    var developer = false
    /// The dictionary's spellings, capped like the engines' bias list.
    var terms: [String] = []
    /// A session prewarmed at key-down for these instructions, if any.
    var session: LanguageModelSession?

    /// Past this, the Light text is worth more than the wait.
    private static let timeout: Duration = .seconds(4)

    func format(_ raw: String) async -> String {
        let light = LightCleanup.apply(raw, language: language, developer: developer)
        guard NameFixer.shouldRun(light, terms: terms), FoundationModelFormatter.isAvailable else { return light }
        let session = session ?? LanguageModelSession(instructions: NameFixer.instructions(terms: terms, language: language))
        let prompt = NameFixer.prompt(for: light, language: language)
        do {
            let proposal = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await session.respond(
                        to: prompt,
                        // Temperature 0 ≈ the greedy decoding measured; `samplingMode:` (Xcode 27 SDK)
                        // is `sampling:` in CI's Xcode 26 SDK, so neither label is used.
                        // A fix is never much longer than what was said.
                        options: GenerationOptions(temperature: 0, maximumResponseTokens: 1200)
                    ).content
                }
                group.addTask {
                    try await Task.sleep(for: Self.timeout)
                    throw CancellationError()
                }
                guard let first = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return first
            }
            return NameFixer.merge(original: light, proposal: proposal, terms: terms)
        } catch {
            Log.speech.info("name fixer skipped (\(error is CancellationError ? "timed out" : "model failed", privacy: .public)) — using rule-based cleanup")
            return light
        }
    }

    // MARK: - Prewarm

    @MainActor private static var prepared: (instructions: String, session: LanguageModelSession)?

    /// At key-down: loads the model with this dictation's instructions while the user speaks.
    @MainActor static func prewarm(terms: [String], language: DictationLanguage) {
        guard FoundationModelFormatter.isAvailable else { return }
        let instructions = NameFixer.instructions(terms: terms, language: language)
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        prepared = (instructions, session)
    }

    /// The session prewarmed for these terms and language, used once; nil if none matches.
    @MainActor static func takeSession(terms: [String], language: DictationLanguage) -> LanguageModelSession? {
        defer { prepared = nil }
        guard let prepared, prepared.instructions == NameFixer.instructions(terms: terms, language: language) else { return nil }
        return prepared.session
    }
}
