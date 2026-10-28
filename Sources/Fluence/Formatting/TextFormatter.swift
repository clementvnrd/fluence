import FluenceCore
import Foundation

/// Raw speech-to-text keeps its fillers, has little or no punctuation and still carries the
/// speaker's spoken self-corrections; this pass sits between the engine and the typing.
/// Implemented by the rules (level Light), by Apple's on-device model (levels Medium and High),
/// and by the test doubles injected through `DictationPipeline`.
protocol TextFormatter: Sendable {
    func format(_ raw: String) async -> String
}

/// Deterministic, zero-latency cleanup (level Light). Good enough to be useful on its own and
/// always the fallback when a model-backed formatter is unavailable, times out or is rejected.
///
/// The rules themselves live in `FluenceCore.LightCleanup` (Clement's repairs, then
/// `RuleCleanup`), where they are unit tested; this only carries the language they run for.
/// A fallback is the whole of Light, never the rules alone (FLU-30).
struct RuleBasedFormatter: TextFormatter {
    /// The transcript's language: fillers and spoken punctuation are language-specific.
    var language: DictationLanguage = .english
    /// Going into a terminal or a code editor: no French typography (FLU-90).
    var developer = false

    func format(_ raw: String) async -> String {
        LightCleanup.apply(raw, language: language, developer: developer)
    }
}

/// Hands the engine's text back as it came, only trimmed: raw output to set beside a cleanup.
struct PassthroughFormatter: TextFormatter {
    func format(_ raw: String) async -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
