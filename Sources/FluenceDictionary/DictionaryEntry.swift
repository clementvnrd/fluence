import Foundation

/// One line of the user's dictionary: a spelling the speech engine should know (a term), or
/// "when the engine writes what was heard, write this instead" (a correction).
public struct DictionaryEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Only biases the speech engine toward `write`; never rewrites text.
        case term
        /// Rewrites `hear` into `write` after transcription; `write` biases the engine too.
        case correction
    }

    /// Stable identity for lists, edits and deletes.
    public var id: UUID
    public var kind: Kind
    /// The right spelling: the word itself for a term, the replacement for a correction.
    public var write: String
    /// What the engine produces instead of `write`, for a correction. Empty for a term.
    public var hear: String
    /// A disabled entry stays in the file but neither corrects nor biases.
    public var isEnabled: Bool

    /// Keeps every value exactly as given: nothing is trimmed or normalized here.
    public init(id: UUID = UUID(), kind: Kind, write: String, hear: String = "", isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.write = write
        self.hear = hear
        self.isEnabled = isEnabled
    }

    /// An enabled term spelled `word`.
    public static func term(_ word: String) -> DictionaryEntry {
        DictionaryEntry(kind: .term, write: word)
    }

    /// An enabled correction turning `hear` into `write`.
    public static func correction(hear: String, write: String) -> DictionaryEntry {
        DictionaryEntry(kind: .correction, write: write, hear: hear)
    }

    /// The entry as one line of `dictionary.txt`: `hear -> write` for a correction, `write` for
    /// a term, behind `# off: ` when disabled. Nothing is trimmed or escaped, so a file saved and
    /// read back is unchanged byte for byte.
    public var fileLine: String {
        let line = kind == .correction ? "\(hear) -> \(write)" : write
        return isEnabled ? line : "# off: \(line)"
    }
}

extension String {
    /// Without leading and trailing whitespace and newlines (Foundation's set, which counts the
    /// zero-width space): how the dictionary reads every trigger and spelling.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
