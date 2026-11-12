import FluenceCore
import Foundation

/// FLU-113: levels Medium and High cleaned by Mistral Small instead of on the Mac, while the
/// cloud engine is on, a Mistral key is saved and « Nettoyage dans le cloud » is on.
///
/// The same instructions as the on-device model (`CleanupPrompt`), from the same Light text,
/// checked by the same guard (`CleanupGuard`, snippet placeholders). Nil whenever the cloud's
/// text is not used — off, slow, failed or rejected — and the caller then cleans on the Mac
/// as if the cloud were off.
enum CloudCleanup {
    /// Past this the on-device cleanup is the shorter wait.
    private static let timeout = 2.5

    @MainActor static var isOn: Bool {
        Settings.shared.cloudProvider != nil && Settings.shared.cloudCleanup && CloudKeys.shared.has(.mistral)
    }

    static func format(
        _ raw: String,
        language: DictationLanguage,
        style: CleanupPrompt.Style?,
        placeholderCount: Int,
        developer: Bool
    ) async -> String? {
        guard let key = try? CloudKeys.shared.key(for: .mistral) else { return nil }
        let light = LightCleanup.apply(raw, language: language, developer: developer)
        if light.isEmpty { return light }

        let request = CloudRequest.cleanup(
            key: key,
            instructions: CleanupPrompt.instructions(language: language, style: style, hasPlaceholders: placeholderCount > 0),
            prompt: CleanupPrompt.prompt(for: light, language: language)
        )
        let outcome = await CloudClient.outcome(of: Task { try await CloudClient.cleanup(request) }, within: timeout)
        guard case .text(var cleaned)? = outcome else {
            let why = outcome.map { if case .failed(let error) = $0 { error.kind } else { "" } } ?? CloudError.timedOut.kind
            Log.speech.info("cloud cleanup not used (\(why, privacy: .public)) — cleaning on the Mac")
            return nil
        }
        let verdict = CleanupGuard.evaluate(original: light, cleaned: cleaned, language: language, restyled: style != nil)
        guard verdict == .accepted else {
            Log.speech.info("cloud cleanup rejected by the guard — cleaning on the Mac")
            return nil
        }
        // A placeholder dropped, doubled or invented would lose or repeat a snippet.
        let blanks = Array(repeating: "", count: placeholderCount)
        guard placeholderCount == 0 || SnippetMatcher.restore(cleaned, expansions: blanks) != nil else {
            Log.speech.info("cloud cleanup changed the snippet placeholders — cleaning on the Mac")
            return nil
        }
        if language == .french, !developer { cleaned = FrenchTypography.apply(to: cleaned) }
        return cleaned
    }
}
