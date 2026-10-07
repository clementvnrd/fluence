import Foundation

/// French punctuation spacing: a non-breaking space before `;` `:` `!` `?` and inside « ».
///
/// Non-breaking (U+00A0) rather than the narrow U+202F that print typography prefers: every
/// font and every text field renders U+00A0, while U+202F still shows as a box or a full
/// space in some apps — and a stray box is worse than a slightly wide gap.
///
/// Idempotent, so it can run after the rules *and* after the model without doubling spaces.
/// Leaves alone what isn't prose: times and ratios (`14:30`), URLs (`https://…?q=1`),
/// e-mail addresses, and a `:` opening a smiley.
public enum FrenchTypography {
    public static let space: Character = "\u{00A0}"

    private static let highPunctuation: Set<Character> = [";", ":", "!", "?"]
    /// Any space-like character that may already sit before the mark.
    private static let gaps: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "\t"]

    public static func apply(to text: String) -> String {
        let characters = Array(text)
        var out: [Character] = []
        out.reserveCapacity(characters.count + 8)

        for (index, character) in characters.enumerated() {
            if highPunctuation.contains(character), shouldSpace(characters, at: index) {
                // Replace whatever gap is there with exactly one non-breaking space.
                while let last = out.last, gaps.contains(last) { out.removeLast() }
                if let last = out.last, last != "\n" { out.append(space) }
                out.append(character)
                continue
            }
            if character == "»" {
                while let last = out.last, gaps.contains(last) { out.removeLast() }
                if let last = out.last, last != "\n", last != "«" { out.append(space) }
                out.append(character)
                continue
            }
            if gaps.contains(character), out.last == "«" {
                continue // the space after « is written once, below
            }
            if out.last == "«", character != "»", character != "\n" {
                out.append(space)
            }
            out.append(character)
        }
        return String(out)
    }

    /// Whether the mark at `index` is prose punctuation rather than part of a token.
    private static func shouldSpace(_ characters: [Character], at index: Int) -> Bool {
        let mark = characters[index]
        let before = index > 0 ? characters[index - 1] : nil
        let after = index + 1 < characters.count ? characters[index + 1] : nil

        // Nothing before it on the line: leave it be.
        guard let before, before != "\n" else { return false }

        let token = surroundingToken(characters, at: index)
        if token.contains("://") || token.hasPrefix("www.") || token.contains("@") { return false }

        switch mark {
        case ":":
            // 14:30, 1:2, and smileys.
            if before.isNumber, after?.isNumber == true { return false }
            if let after, ")(/".contains(after) { return false }
            return true
        case "?", "!":
            // A query string or anchor inside a path: "page.php?id=2".
            if let after, !gaps.contains(after), after.isLetter || after.isNumber || after == "=" {
                return false
            }
            // "?!" and "!!": the second mark follows the first directly.
            if highPunctuation.contains(before) { return false }
            return true
        default:
            return true
        }
    }

    /// The run of non-space characters around `index`.
    private static func surroundingToken(_ characters: [Character], at index: Int) -> String {
        var start = index
        while start > 0, !gaps.contains(characters[start - 1]), characters[start - 1] != "\n" { start -= 1 }
        var end = index
        while end + 1 < characters.count, !gaps.contains(characters[end + 1]), characters[end + 1] != "\n" { end += 1 }
        return String(characters[start...end]).lowercased()
    }
}
