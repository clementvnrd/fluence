import Foundation

/// How a shortcut is written in sentences and chips (FLU-12): "⌥ Espace", "⌃ ⌥", "⌥ droite".
///
/// Shortcuts reach the UI as the short name they were saved with — a preset ("⌥ Espace"), a
/// combination recorded in Settings ("⌘ ⇧ Espace"), or one migrated from an older build that
/// may spell keys in words ("Right Option", "rightOption"). Whatever it is, the label shows
/// modifier symbols, the side in French ("droite", "gauche") and French key names, joined by
/// non-breaking spaces so a shortcut never wraps across two lines.
public enum ShortcutLabel {
    /// Non-breaking space between the parts of one shortcut.
    public static let joiner = "\u{00A0}"

    /// The label for a stored short name.
    public static func display(_ shortName: String) -> String {
        tokens(shortName).joined(separator: joiner)
    }

    /// "⌥ + Espace": with a plus between the parts, for hints such as "double-tap ou ⌥ + Espace".
    public static func spelled(_ shortName: String) -> String {
        tokens(shortName).joined(separator: joiner + "+" + joiner)
    }

    /// Just the modifier symbols, for the compact status chip: "Raccourci ⌥", "⌥ droite",
    /// "⌃⌥⌘" (several bare symbols run together, as macOS writes them in menus).
    public static func modifiers(_ shortName: String) -> String {
        let symbols = tokens(shortName).filter { $0.unicodeScalars.first.map(isModifierSymbol) ?? false }
        if symbols.isEmpty { return display(shortName) }
        return symbols.joined(separator: symbols.allSatisfy { $0.unicodeScalars.count == 1 } ? "" : joiner)
    }

    // MARK: Parsing

    static func tokens(_ shortName: String) -> [String] {
        // camelCase legacy values ("rightOption") become words first.
        var spaced = ""
        for character in shortName {
            if character.isUppercase, let last = spaced.last, last.isLowercase {
                spaced.append(" ")
            }
            spaced.append(character)
        }
        let words = spaced
            .replacingOccurrences(of: "+", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        var result: [String] = []
        var pendingSide: String?
        for word in words {
            let lower = word.lowercased()
            if let side = sides[lower] {
                pendingSide = side
                continue
            }
            if let symbol = modifierNames[lower] ?? (word.unicodeScalars.count == 1 && isModifierSymbol(word.unicodeScalars.first!) ? word : nil) {
                if let side = pendingSide {
                    result.append(symbol + joiner + side)
                    pendingSide = nil
                } else {
                    result.append(symbol)
                }
                continue
            }
            result.append(keyNames[lower] ?? word)
        }
        if let side = pendingSide { result.append(side) }
        return result
    }

    private static func isModifierSymbol(_ scalar: Unicode.Scalar) -> Bool {
        ["⌘", "⌥", "⌃", "⇧"].contains(String(scalar))
    }

    private static let sides: [String: String] = [
        "right": "droite", "droite": "droite", "droit": "droite",
        "left": "gauche", "gauche": "gauche",
    ]

    private static let modifierNames: [String: String] = [
        "option": "⌥", "opt": "⌥", "alt": "⌥",
        "command": "⌘", "cmd": "⌘", "commande": "⌘",
        "control": "⌃", "ctrl": "⌃", "contrôle": "⌃", "controle": "⌃",
        "shift": "⇧", "maj": "⇧",
    ]

    private static let keyNames: [String: String] = [
        "space": "Espace", "espace": "Espace", "␣": "Espace",
        "return": "Entrée", "enter": "Entrée",
        "escape": "Échap", "esc": "Échap",
        "delete": "Suppr", "tab": "Tab", "fn": "fn",
    ]
}

/// Initials and a stable colour slot for a person's name, for avatars (FLU-12).
public enum PersonInitials {
    /// "Camille Martin" → "CM", "Vous" → "VO", "Intervenant 2" → "2", "jean-pierre dupont" → "JD".
    public static func of(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return "?" }
        // A numbered, unnamed speaker shows its number.
        if let last = words.last, words.count > 1, last.allSatisfy(\.isNumber) { return last }
        let letters = words.compactMap { $0.first(where: \.isLetter) }
        if letters.count >= 2 { return String([letters[0], letters[letters.count - 1]]).uppercased() }
        let word = words[0].filter(\.isLetter)
        return String(word.prefix(2)).uppercased().isEmpty ? "?" : String(word.prefix(2)).uppercased()
    }

    /// A slot in `0..<count`, the same for a name on every launch (`hashValue` is seeded
    /// per process, so it can't be used).
    public static func slot(for name: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}
