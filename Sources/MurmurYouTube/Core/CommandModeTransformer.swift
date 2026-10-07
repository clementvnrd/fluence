import Foundation
import FoundationModels

/// Transforms selected text based on a spoken instruction (Command Mode).
///
/// Uses Apple's Foundation Models on-device LLM when available, with deterministic
/// rule-based transformations as fallback.
enum CommandModeTransformer {
    static func transform(selectedText: String, instruction: String) async -> String {
        let trimmedSelected = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSelected.isEmpty else { return trimmedSelected }
        guard !trimmedInstruction.isEmpty else { return trimmedSelected }

        if FoundationModelFormatter.isAvailable {
            do {
                let transformed = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        let session = LanguageModelSession(instructions: """
                            You are an expert text editor and transformer. Apply the user's instruction \
                            directly to the provided text.
                            Rules:
                            - Return ONLY the transformed text.
                            - No conversational preamble ("Here is..."), no quotes, no explanations.
                            - If asked to summarize, make formal, rephrase, or translate, do so accurately.
                            - Instructions and text can be in French or English. Output in the requested language.
                            - Preserve formatting, casing, or tone unless instructed otherwise.
                            """)

                        let prompt = """
                            Instruction: \(trimmedInstruction)

                            Text to transform:
                            \(trimmedSelected)
                            """

                        let response = try await session.respond(
                            to: prompt,
                            options: GenerationOptions(
                                temperature: 0.2,
                                maximumResponseTokens: 2_000
                            )
                        )
                        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    group.addTask {
                        try await Task.sleep(for: .seconds(5))
                        throw CancellationError()
                    }

                    guard let result = try await group.next() else { throw CancellationError() }
                    group.cancelAll()
                    return result
                }

                if !transformed.isEmpty {
                    Log.speech.info("Command Mode: successfully transformed via Foundation Models")
                    return transformed
                }
            } catch {
                Log.speech.info("Command Mode: Foundation Models failed or timed out (\(error.localizedDescription)) — using fallback")
            }
        }

        return fallbackTransform(selectedText: trimmedSelected, instruction: trimmedInstruction)
    }

    private static func fallbackTransform(selectedText: String, instruction: String) -> String {
        let lower = instruction.lowercased()

        // 1. Lists / bullets
        if lower.contains("bullet") || lower.contains("list") || lower.contains("liste") || lower.contains("puce") || lower.contains("tiret") {
            let lines = selectedText.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return lines.map { "- \($0)" }.joined(separator: "\n")
        }

        // 2. Numbered lists
        if lower.contains("number") || lower.contains("numéro") {
            let lines = selectedText.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }

        // 3. Case conversions
        if lower.contains("uppercase") || lower.contains("all caps") || lower.contains("majuscule") {
            return selectedText.uppercased()
        }
        if lower.contains("lowercase") || lower.contains("minuscule") {
            return selectedText.lowercased()
        }

        // 4. Formal / cleanup
        if lower.contains("formal") || lower.contains("clean") || lower.contains("propre") || lower.contains("polish") {
            // Strip casual fillers and capitalize
            var cleaned = selectedText
            let casual = ["like,", "you know,", "um,", "uh,", "actually,"]
            for word in casual {
                cleaned = cleaned.replacingOccurrences(of: "(?i)\\b\(word)\\b", with: "", options: .regularExpression)
            }
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return selectedText
    }
}
