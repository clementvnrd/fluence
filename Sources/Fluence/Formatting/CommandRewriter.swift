import FluenceCore
import Foundation
import FoundationModels

/// Command Mode's rewrite (FLU-5): apply a spoken instruction to a piece of text with Apple's
/// on-device model. Nothing leaves the Mac, and nothing here logs the text or the
/// instruction — only lengths and the reason for a failure.
///
/// What is asked, and whether the answer may replace the user's text, is decided in
/// `CommandRewrite` (FluenceCore, tested). This file only talks to the model.
enum CommandRewriter {
    enum Failure: Error {
        case unavailable
        case timedOut
        case declined
        case unsupportedLanguage
        case tooLong
        case rejected
        case unchanged
        case failed

        /// What the HUD says: plain words, short enough for its two-line readout. The user
        /// is mid-task in another app; Settings explains the details.
        var message: String {
            switch self {
            case .unavailable: "Le Mode Commande nécessite Apple Intelligence."
            case .timedOut: "La réécriture a pris trop de temps. Rien n'a changé."
            case .declined: "Le modèle d'Apple a refusé ce texte."
            case .unsupportedLanguage: "Le modèle d'Apple ne prend pas en charge cette langue."
            case .tooLong: "Trop de texte. Sélectionnez un passage plus court."
            case .rejected: "La réécriture semblait incorrecte. Rien n'a changé."
            case .unchanged: "Rien à changer."
            case .failed: "La réécriture a échoué. Rien n'a changé."
            }
        }

        /// For the log: never the text.
        var reason: String {
            switch self {
            case .unavailable: "model unavailable"
            case .timedOut: "timed out"
            case .declined: "declined by the model"
            case .unsupportedLanguage: "unsupported language"
            case .tooLong: "context window exceeded"
            case .rejected: "output rejected"
            case .unchanged: "unchanged"
            case .failed: "generation failed"
            }
        }
    }

    static func rewrite(_ text: String, instruction: String) async -> Result<String, Failure> {
        guard FoundationModelFormatter.isAvailable else { return .failure(.unavailable) }

        let timeout = CommandRewrite.timeout(forCharacters: text.count)
        let output: String
        do {
            output = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await respond(text, instruction: instruction) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw CancellationError()
                }
                // Whichever finishes first wins; cancel the loser.
                guard let first = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return first
            }
        } catch let error as LanguageModelSession.GenerationError {
            return .failure(failure(for: error))
        } catch is CancellationError {
            return .failure(.timedOut)
        } catch {
            return .failure(.failed)
        }

        switch CommandRewrite.sanitize(output, original: text) {
        case .accepted(let rewritten):
            Log.speech.info("command · rewrote \(text.count, privacy: .public) → \(rewritten.count, privacy: .public) chars")
            return .success(rewritten)
        case .unchanged:
            return .failure(.unchanged)
        case .empty:
            Log.speech.info("command · output rejected (empty)")
            return .failure(.rejected)
        case .tooLong(let ratio):
            Log.speech.info("command · output rejected (length ratio \(String(format: "%.1f", ratio), privacy: .public))")
            return .failure(.rejected)
        }
    }

    private static func respond(_ text: String, instruction: String) async throws -> String {
        let session = LanguageModelSession(instructions: CommandRewrite.instructions)
        let response = try await session.respond(
            to: CommandRewrite.prompt(instruction: instruction, text: text),
            options: GenerationOptions(
                // Low but not zero: "make it friendlier" needs some freedom of wording.
                temperature: 0.3,
                maximumResponseTokens: CommandRewrite.maximumResponseTokens(forCharacters: text.count)
            )
        )
        return response.content
    }

    private static func failure(for error: LanguageModelSession.GenerationError) -> Failure {
        switch error {
        case .exceededContextWindowSize: .tooLong
        case .guardrailViolation, .refusal: .declined
        case .unsupportedLanguageOrLocale: .unsupportedLanguage
        case .assetsUnavailable: .unavailable
        default: .failed
        }
    }
}
