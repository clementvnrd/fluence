import Foundation

/// Word-level text comparison for the echo backstop.
///
/// This is a contract (Tests/FluenceMeetingCoreTests/meeting-test-vectors.json,
/// `normalization`). The rules, in order:
///
/// 1. Unicode NFKD (compatibility decomposition).
/// 2. Drop every non-spacing combining mark (general category Mn) — `é` → `e`.
/// 3. Lowercase.
/// 4. Every character that is not a letter or a digit becomes a space.
/// 5. Split on whitespace; drop empty pieces.
public enum TextTokens {
    public static func normalize(_ text: String) -> [String] {
        let decomposed = text.decomposedStringWithCompatibilityMapping
        var folded = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars where scalar.properties.generalCategory != .nonspacingMark {
            folded.append(scalar)
        }
        let lowered = String(folded).lowercased()

        var tokens: [String] = []
        var current = ""
        for character in lowered {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// |A ∩ B| / |A ∪ B| over token *sets*. Two empty sets score 0: nothing to match is
    /// never a duplicate.
    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }
}
