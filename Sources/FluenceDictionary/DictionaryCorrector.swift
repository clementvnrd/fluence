import Foundation

/// One correction that fired on one text, kept in the history so the user sees the dictionary
/// at work. Stored on disk as `{"from", "to", "count"}`: keep these three keys.
public struct AppliedCorrection: Codable, Hashable, Sendable {
    /// What the text held at the first match, in its own case and spacing.
    public let from: String
    /// What it became: the entry's `write`.
    public let to: String
    /// How many matches it changed in that text.
    public let count: Int
}

/// The deterministic pass that runs after transcription and rewrites what the dictionary's
/// corrections say. Built once from the entries, then safe to share across threads and actors.
public struct DictionaryCorrector: Sendable {
    /// Longest trigger first; equal lengths keep the order of the entries.
    private let rules: [CorrectionRule]

    /// Entries that cannot correct anything (terms, disabled entries, blank triggers) are left
    /// out without a word.
    public init(entries: [DictionaryEntry]) {
        let built = entries.enumerated().compactMap { index, entry in
            CorrectionRule(entry).map { (index: index, rule: $0) }
        }
        rules = built
            .sorted { $0.rule.length != $1.rule.length ? $0.rule.length > $1.rule.length : $0.index < $1.index }
            .map(\.rule)
    }

    /// True when no entry became a correction.
    public var isEmpty: Bool { rules.isEmpty }

    /// Runs every correction in turn on the text as the previous ones left it, so a longer
    /// trigger claims its words before a shorter one sees them. Each correction replaces all its
    /// matches, left to right, and is reported once with how many it changed. A write that opens
    /// a sentence the engine capitalised takes that capital. The text comes back in NFC,
    /// except what a `write` inserts, which is kept as typed; with no correction or no text, it
    /// comes back untouched.
    public func apply(to text: String) -> (text: String, applied: [AppliedCorrection]) {
        if rules.isEmpty || text.isEmpty { return (text, []) }
        var current = NSString(string: text.precomposedStringWithCanonicalMapping)
        var applied: [AppliedCorrection] = []
        for rule in rules {
            let matches = rule.pattern.matches(in: current as String, range: NSRange(location: 0, length: current.length))
            guard !matches.isEmpty else { continue }
            let rewritten = NSMutableString(capacity: current.length)
            var cursor = 0
            var changed: [String] = []
            for match in matches {
                let found = current.substring(with: match.range)
                let opens = Self.opensSentence(found, at: match.range.location, in: current)
                let inserted = opens ? Self.capitalized(rule.replacement) : rule.replacement
                // A match already written as the write changes nothing: no correction to show.
                if found != inserted { changed.append(found) }
                rewritten.append(current.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                rewritten.append(inserted)
                cursor = NSMaxRange(match.range)
            }
            rewritten.append(current.substring(from: cursor))
            current = rewritten
            if let from = changed.first {
                applied.append(AppliedCorrection(from: from, to: rule.replacement, count: changed.count))
            }
        }
        return (current as String, applied)
    }

    /// A match the engine capitalised as a sentence start (« La pière », not « NEXT JS »), at
    /// the text's start, a line's, or after . ! ? (FLU-137: « la PR est prête » lost its capital).
    private static func opensSentence(_ found: String, at location: Int, in text: NSString) -> Bool {
        let letters = found.prefix(2)
        guard letters.first?.isUppercase == true, letters.last?.isLowercase == true else { return false }
        var index = location - 1
        while index >= 0, [0x20, 0x09].contains(text.character(at: index)) { index -= 1 }
        guard index >= 0 else { return true }
        guard let previous = Unicode.Scalar(text.character(at: index)) else { return false }
        return Character(previous).isNewline || ".!?".unicodeScalars.contains(previous)
    }

    private static func capitalized(_ write: String) -> String {
        guard let first = write.first, first.isLowercase else { return write }
        return first.uppercased() + write.dropFirst()
    }
}
