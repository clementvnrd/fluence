import FluenceCore
import Foundation
import FoundationModels

/// Cleanup via Apple's on-device LLM (macOS 26 Foundation Models).
///
/// This is the pass that separates dictation from *usable* dictation: it removes fillers,
/// restores punctuation and paragraphing, formats spoken lists, and — the thing rules can
/// never do — honors mid-sentence corrections like "make that three, actually".
///
/// Three properties make it safe to put in the hot path:
/// - **On-device.** Nothing leaves the Mac, so it's viable for anything you'd dictate.
/// - **Bounded.** A timeout falls back to `RuleBasedFormatter`, because a stalled model
///   must never cost you an utterance you already spoke.
/// - **Guarded.** Output is rejected if it looks like the model answered the text instead
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

    /// Deterministic fallback used on timeout, unavailability, or a rejected response.
    private var fallback: RuleBasedFormatter { RuleBasedFormatter(language: language) }

    /// Past this, taking the raw text beats making the user wait.
    private let timeout: Duration = .seconds(4)

    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off in System Settings."
            case .modelNotReady: return "The on-device model is still downloading."
            @unknown default: return "The on-device model is unavailable."
            }
        @unknown default:
            return "The on-device model is unavailable."
        }
    }

    func format(_ raw: String) async -> String {
        // Light first: the model starts from text with the fillers gone and the spoken
        // commands already turned into punctuation, and the fallback is that same text.
        let trimmed = await fallback.format(raw)
        guard !trimmed.isEmpty else { return trimmed }

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
                    try await Task.sleep(for: timeout)
                    throw CleanupError.timedOut
                }
                // Whichever finishes first wins; cancel the loser.
                guard let first = try await group.next() else { throw CleanupError.timedOut }
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
            Log.speech.info("Foundation model cleanup failed (\(Self.describe(error), privacy: .public)) — falling back")
            return trimmed
        }
    }

    /// Every failure here degrades to `RuleBasedFormatter` — the user still gets their
    /// words. This exists to make the *reason* legible in the log, because the cases have
    /// very different meanings: `guardrailViolation` and `refusal` are the model declining
    /// content (expected occasionally, not a bug), while `assetsUnavailable` means the
    /// feature is effectively off and the user should be told.
    private static func describe(_ error: Error) -> String {
        guard let error = error as? LanguageModelSession.GenerationError else {
            return error.localizedDescription
        }
        switch error {
        case .exceededContextWindowSize: return "input exceeded the context window"
        case .assetsUnavailable: return "model assets unavailable"
        case .guardrailViolation: return "blocked by safety guardrails"
        case .unsupportedGuide: return "unsupported generation guide"
        case .unsupportedLanguageOrLocale: return "unsupported language"
        case .decodingFailure: return "decoding failure"
        case .rateLimited: return "rate limited"
        case .concurrentRequests: return "concurrent request on one session"
        case .refusal: return "model refused the content"
        @unknown default: return error.localizedDescription
        }
    }

    private static func clean(_ prompt: String, instructions: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)

        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(
                // Near-deterministic: this is a formatting pass, not a creative one.
                temperature: 0.1,
                // Cleanup should never be much longer than the input; this bounds a runaway.
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

    private enum CleanupError: LocalizedError {
        case timedOut
        var errorDescription: String? { "on-device cleanup timed out" }
    }
}
