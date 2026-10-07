import Foundation

/// A conservative token estimate, used when the SDK cannot count for us
/// (`SystemLanguageModel.tokenCount(for:)` only exists from macOS 26.4).
///
/// Apple's tokenizer averages roughly four characters per token on English prose. French,
/// names, timestamps and punctuation-heavy transcript lines come out shorter per token, so
/// this divides by three: it over-counts by about a quarter on typical text, and over-counting
/// only costs an extra chunk, while under-counting overflows the context and loses the call.
public enum TokenEstimate {
    public static func tokens(in text: String) -> Int {
        let characters = text.unicodeScalars.count
        guard characters > 0 else { return 0 }
        return (characters + 2) / 3
    }
}

/// How the on-device context is shared between instructions, transcript and answer.
///
/// The system model has one window (4,096 tokens on macOS 26) for *everything*: the
/// instructions, the generation schema the framework injects, the prompt and the response.
/// The chunk size is what is left once the rest is reserved.
public struct NotesBudget: Sendable, Hashable {
    /// The model's whole window.
    public var contextSize: Int
    /// Reserved for the answer, and passed as `maximumResponseTokens`.
    public var responseTokens: Int
    /// Instructions, the injected schema and the prompt framing (title, participants, part
    /// numbers). Measured at about 550 tokens; rounded up.
    public var overheadTokens: Int
    /// The user's own notes are sent with every chunk; past this they are truncated.
    public var userNotesTokens: Int
    /// Upper bound on a transcript chunk even when the window is larger: smaller chunks
    /// give the model less to skim over, and the design targets ~2,500.
    public var maximumChunkTokens: Int

    public init(
        contextSize: Int,
        responseTokens: Int = 800,
        overheadTokens: Int = 700,
        userNotesTokens: Int = 300,
        maximumChunkTokens: Int = 2_500
    ) {
        self.contextSize = contextSize
        self.responseTokens = responseTokens
        self.overheadTokens = overheadTokens
        self.userNotesTokens = userNotesTokens
        self.maximumChunkTokens = maximumChunkTokens
    }

    /// Tokens available for transcript lines in one call.
    /// With a 4,096 window: 2,296 when the user typed notes, 2,500 otherwise.
    public func chunkTokens(hasUserNotes: Bool) -> Int {
        let free = contextSize - responseTokens - overheadTokens - (hasUserNotes ? userNotesTokens : 0)
        return max(256, min(maximumChunkTokens, free))
    }

    /// Tokens available for the merged extractions fed to the reduce step.
    public func reduceInputTokens(hasUserNotes: Bool) -> Int {
        chunkTokens(hasUserNotes: hasUserNotes)
    }

    /// Whether a fully assembled call (instructions + prompt, measured) still leaves room
    /// for the answer.
    public func fits(promptTokens: Int, schemaTokens: Int = 0) -> Bool {
        promptTokens + schemaTokens + responseTokens <= contextSize
    }
}
