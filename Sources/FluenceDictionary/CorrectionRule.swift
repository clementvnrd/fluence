import Foundation

/// One correction, ready to run: its trigger compiled once into a pattern, and the text that
/// replaces each match.
///
/// A trigger is read in parts, split at spaces, hyphens and tabs. A match is the parts in order,
/// each one literal and case-insensitive (ICU folding, with no Turkish rules), with nothing or
/// any mix of whitespace and hyphens between two parts: "cloud code" matches "CloudCode",
/// "cloud-code" and "cloud  code". A letter or a digit right before or after the match makes it
/// part of a longer word, and then it does not count.
struct CorrectionRule: Sendable {
    let pattern: NSRegularExpression
    let replacement: String
    /// Characters in the trimmed, NFC trigger. Longer triggers run first.
    let length: Int

    /// Nil when the entry cannot correct anything: a term, a disabled entry, or a trigger with
    /// nothing in it but whitespace, hyphens and tabs.
    init?(_ entry: DictionaryEntry) {
        guard entry.isEnabled, entry.kind == .correction else { return nil }
        let trigger = entry.hear.precomposedStringWithCanonicalMapping.trimmed
        let parts = trigger.components(separatedBy: Self.separators).filter { !$0.isEmpty }
        guard !parts.isEmpty, let pattern = try? NSRegularExpression(pattern: Self.pattern(for: parts)) else {
            return nil
        }
        self.pattern = pattern
        self.replacement = entry.write
        self.length = trigger.count
    }

    /// Where a trigger splits into parts. Nothing else does: a no-break space, a newline or an
    /// en dash inside a trigger is matched as itself.
    private static let separators = CharacterSet(charactersIn: " -\t")

    /// The parts, each escaped so `.`, `+`, `$`, `\` and the like mean themselves, joined by
    /// the gap (ICU's `\s` is exactly Unicode White_Space) and fenced by the word boundaries.
    /// Only the parts are case-insensitive: under the flag, ICU would widen the letter class to
    /// every character that folds to a letter, such as the combining mark U+0345, and a mark
    /// next to a match must stay a boundary.
    private static func pattern(for parts: [String]) -> String {
        let literals = parts.map { "(?i:\(NSRegularExpression.escapedPattern(for: $0)))" }
        return #"(?<![\p{L}\p{N}])"# + literals.joined(separator: #"[\s\-]*"#) + #"(?![\p{L}\p{N}])"#
    }
}
