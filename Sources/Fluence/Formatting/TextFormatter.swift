import FluenceCore
import Foundation

/// The cleanup pass between raw transcription and injection.
///
/// This is where Wispr Flow actually earns its keep — raw STT output is full of filler
/// words, missing punctuation, and spoken corrections. Swapping in an LLM-backed
/// formatter (Apple Foundation Models on-device, or Claude for the high-quality tier)
/// is the point of keeping this behind a protocol.
protocol TextFormatter: Sendable {
    func format(_ raw: String) async -> String
}

/// Deterministic, zero-latency cleanup (level Light). Good enough to be useful on its own and
/// always the fallback when a model-backed formatter is unavailable, times out or is rejected.
///
/// The rules themselves live in `FluenceCore.RuleCleanup`, where they are unit tested; this
/// only carries the language they run for.
struct RuleBasedFormatter: TextFormatter {
    /// The transcript's language: fillers and spoken punctuation are language-specific.
    var language: DictationLanguage = .english

    func format(_ raw: String) async -> String {
        RuleCleanup.apply(raw, language: language)
    }
}

/// No-op formatter, for comparing raw engine output against the cleanup pass.
struct PassthroughFormatter: TextFormatter {
    func format(_ raw: String) async -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
