import FluenceCore
import Foundation
import FoundationModels

/// Cleanup by Apple's on-device language model (Foundation Models, macOS 26).
///
/// Beyond the rules, it drops fillers, restores punctuation and paragraphs, lays out spoken
/// lists, and applies a correction made halfway through a sentence ("ten, no, twelve"), which
/// no rule can do. It is safe on the dictation path because it is:
/// - private: it runs on the Mac and nothing leaves it, so anything may be dictated;
/// - bounded: a stalled model must never cost words already spoken, so after a time limit the
///   `RuleBasedFormatter` text is used instead;
/// - checked: its output is refused when the model seems to have answered the text instead
///   of cleaning it — the classic failure when dictation reads as an instruction — or if it
///   dropped too much of what was said. See `CleanupGuard`.
///
/// Levels Medium and High (FLU-5). The rules run first — they turn spoken commands into
/// marks the model would otherwise read as words — and the model works on their output, so
/// a rejected or failed model pass costs nothing but the model's own improvements.
struct FoundationModelFormatter: TextFormatter {
    /// The transcript's language: picks the instructions and the guard's word lists.
    var language: DictationLanguage = .english
    /// Level High: the style for the kind of app being typed into. Nil at Medium.
    var style: CleanupPrompt.Style?
    /// How many snippet placeholders (⟦1⟧…) the text carries. The model must hand every one
    /// back exactly once, or its output is not used.
    var placeholderCount = 0

    /// The deterministic answer, whenever the model is unavailable, too slow, failing or rejected.
    private var fallback: RuleBasedFormatter { RuleBasedFormatter(language: language) }

    /// Past this, the rules' text is worth more than the wait.
    private static let timeout: Duration = .seconds(4)

    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "Ce Mac ne prend pas en charge Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Apple Intelligence est désactivé dans Réglages Système."
            case .modelNotReady: return "Le modèle local est encore en cours de téléchargement."
            @unknown default: return "Le modèle local est indisponible."
            }
        @unknown default:
            return "Le modèle local est indisponible."
        }
    }

    func format(_ raw: String) async -> String {
        // Light first: the model starts from text with the fillers gone and the spoken
        // commands already turned into punctuation, and the fallback is that same text.
        let trimmed = await fallback.format(raw)
        if trimmed.isEmpty { return trimmed }

        guard Self.isAvailable else {
            Log.speech.info("Foundation model unavailable — using rule-based cleanup")
            return trimmed
        }

        let instructions = CleanupPrompt.instructions(
            language: language,
            style: style,
            hasPlaceholders: placeholderCount > 0
        )
        let prompt = CleanupPrompt.prompt(for: trimmed, language: language)

        do {
            var cleaned = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await Self.clean(prompt, instructions: instructions) }
                group.addTask {
                    try await Task.sleep(for: Self.timeout)
                    throw CleanupTimeout.expired
                }
                // The first child to finish decides; the other one is cancelled.
                guard let first = try await group.next() else { throw CleanupTimeout.expired }
                group.cancelAll()
                return first
            }

            let verdict = CleanupGuard.evaluate(
                original: trimmed,
                cleaned: cleaned,
                language: language,
                restyled: style != nil
            )
            guard verdict == .accepted else {
                Log.speech.info("Foundation model output rejected (\(Self.describe(verdict), privacy: .public)) — using rule-based cleanup")
                return trimmed
            }
            // A placeholder dropped, doubled or invented would lose or repeat a snippet.
            let blanks = Array(repeating: "", count: placeholderCount)
            guard placeholderCount == 0 || SnippetMatcher.restore(cleaned, expansions: blanks) != nil else {
                Log.speech.info("Foundation model output rejected (snippet placeholders changed) — using rule-based cleanup")
                return trimmed
            }
            // Typography is deterministic and idempotent: the model's spacing is not trusted.
            if language == .french { cleaned = FrenchTypography.apply(to: cleaned) }
            return cleaned
        } catch {
            Log.speech.info("Foundation model cleanup failed (\(Self.describe(error), privacy: .public)) — using rule-based cleanup")
            return trimmed
        }
    }

    /// Why the model pass failed, in a few words for the log. The user keeps their words
    /// whatever the case (the rules' text goes out), but the cases mean very different things:
    /// a guardrail violation or a refusal is the model declining this content, which happens and
    /// is no bug, while missing assets mean the feature is effectively off and the user should
    /// be told.
    private static func describe(_ error: Error) -> String {
        guard let error = error as? LanguageModelSession.GenerationError else {
            return error.localizedDescription
        }
        switch error {
        case .exceededContextWindowSize: return "context window exceeded"
        case .assetsUnavailable: return "model assets unavailable"
        case .guardrailViolation: return "guardrail violation"
        case .unsupportedGuide: return "unsupported guide"
        case .unsupportedLanguageOrLocale: return "unsupported language or locale"
        case .decodingFailure: return "decoding failure"
        case .rateLimited: return "rate limited"
        case .concurrentRequests: return "concurrent requests"
        case .refusal: return "refused by the model"
        @unknown default: return error.localizedDescription
        }
    }

    private static func clean(_ prompt: String, instructions: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)

        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(
                // Formatting, not writing: as close to deterministic as it usefully gets.
                temperature: 0.1,
                // A cleanup is never much longer than what was said; this stops a runaway reply.
                maximumResponseTokens: 1_200
            )
        )

        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the guard said no — counts and ratios only, never the words, which are the
    /// user's dictation.
    private static func describe(_ verdict: CleanupGuard.Verdict) -> String {
        switch verdict {
        case .accepted: "accepted"
        case .empty: "empty output"
        case .inventedWords(let count): "\(count) invented word(s)"
        case .lengthRatio(let ratio): "length ratio \(String(format: "%.2f", ratio))"
        case .commentary: "model commentary"
        }
    }

    private enum CleanupTimeout: LocalizedError {
        case expired
        var errorDescription: String? { "on-device cleanup timed out" }
    }
}
