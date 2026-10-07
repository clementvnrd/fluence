import Foundation

/// A voice shortcut: say the trigger, get the stored text, exactly as stored.
public struct Snippet: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// What you say. Matched case- and accent-insensitively, as whole words.
    public var trigger: String
    /// What gets typed, verbatim — never cleaned up, restyled or dictionary-corrected.
    public var expansion: String
    /// Switched off in the snippets panel: kept, but never expanded.
    public var isEnabled: Bool
    /// When the snippet was made; the panel lists the newest first.
    public var createdAt: Date?

    /// Wispr Flow's limits. A trigger is something you say in one breath; an expansion is a
    /// paragraph or an address, not a document.
    public static let triggerLimit = 60
    public static let expansionLimit = 4_000

    public init(
        id: UUID = UUID(),
        trigger: String,
        expansion: String,
        isEnabled: Bool = true,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, trigger, expansion, isEnabled, createdAt
    }

    /// Lenient: snippets sealed before `isEnabled` existed decode as enabled.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        trigger = try container.decode(String.self, forKey: .trigger)
        expansion = try container.decode(String.self, forKey: .expansion)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    /// Why this snippet can't be saved as it is, or nil.
    public func problem(among others: [Snippet]) -> String? {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = SnippetMatcher.words(in: trigger)
        if words.isEmpty { return "Le déclencheur doit contenir au moins un mot." }
        if trigger.count > Self.triggerLimit { return "Un déclencheur fait au plus \(Self.triggerLimit) caractères." }
        if expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Le texte à insérer est vide." }
        if expansion.count > Self.expansionLimit { return "Le texte est limité à \(Self.expansionLimit) caractères." }
        let key = words.map(\.key)
        if others.contains(where: { $0.id != id && SnippetMatcher.words(in: $0.trigger).map(\.key) == key }) {
            return "Un autre snippet utilise déjà ce déclencheur."
        }
        return nil
    }
}

/// Finds snippet triggers in a transcript, and shields their expansions from cleanup.
///
/// Matching is on words, not characters: the transcript's words and the trigger's words are
/// folded (case, accents, curly apostrophes) and compared one by one, and between two words
/// of a match only spaces, commas or hyphens may sit — what an engine puts between words it
/// heard together. A sentence break between them is two utterances, not one trigger.
///
/// Where triggers overlap, the longest wins ("my work address" over "my address").
public enum SnippetMatcher {
    public struct Match: Sendable, Equatable {
        public let range: Range<String.Index>
        public let snippet: Snippet
    }

    struct Word {
        let range: Range<String.Index>
        let key: String
    }

    /// The snippet the whole utterance is, punctuation aside — "My address." is exactly the
    /// trigger "my address", and gets its expansion with nothing around it.
    ///
    /// A leading command word is allowed, as in Clement's build: "insert my address",
    /// "colle ma signature" expand like the bare trigger.
    public static func wholeUtterance(_ text: String, snippets: [Snippet]) -> Snippet? {
        let spoken = words(in: text).map(\.key)
        guard !spoken.isEmpty else { return nil }
        if let exact = snippets.first(where: { words(in: $0.trigger).map(\.key) == spoken }) {
            return exact
        }
        guard spoken.count > 1, commandWords.contains(spoken[0]) else { return nil }
        let rest = Array(spoken.dropFirst())
        return snippets.first { words(in: $0.trigger).map(\.key) == rest }
    }

    /// Spoken before a trigger to ask for it, in English and French (folded, like keys).
    static let commandWords: Set<String> = ["insert", "paste", "add", "type", "insere", "colle"]

    /// Every trigger spoken inside `text`, non-overlapping, in text order.
    public static func matches(in text: String, snippets: [Snippet]) -> [Match] {
        let spoken = words(in: text)
        guard !spoken.isEmpty else { return [] }

        var candidates: [(start: Int, count: Int, snippet: Snippet)] = []
        for snippet in snippets {
            let trigger = words(in: snippet.trigger).map(\.key)
            guard !trigger.isEmpty, trigger.count <= spoken.count else { continue }
            for start in 0...(spoken.count - trigger.count) where matches(trigger, spoken, at: start, in: text) {
                candidates.append((start, trigger.count, snippet))
            }
        }

        // Longest first (in words, then characters), earliest first among equals.
        candidates.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.snippet.trigger.count != $1.snippet.trigger.count {
                return $0.snippet.trigger.count > $1.snippet.trigger.count
            }
            return $0.start < $1.start
        }
        var taken = Set<Int>()
        var chosen: [Match] = []
        for candidate in candidates {
            let span = Set(candidate.start..<(candidate.start + candidate.count))
            guard taken.isDisjoint(with: span) else { continue }
            taken.formUnion(span)
            let range = spoken[candidate.start].range.lowerBound..<spoken[candidate.start + candidate.count - 1].range.upperBound
            chosen.append(Match(range: range, snippet: candidate.snippet))
        }
        return chosen.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: - Shielding expansions from cleanup

    /// The transcript with each spoken trigger replaced by a placeholder (⟦1⟧, ⟦2⟧…), and the
    /// expansions in placeholder order.
    ///
    /// Cleanup then runs on text that contains no snippet at all, so neither the rules nor
    /// the model can touch an expansion — the model is told to copy placeholders as they
    /// are, and `restore` checks that it did.
    public static func protect(_ text: String, snippets: [Snippet]) -> (text: String, expansions: [String]) {
        let found = matches(in: text, snippets: snippets)
        guard !found.isEmpty else { return (text, []) }
        var result = ""
        var cursor = text.startIndex
        var expansions: [String] = []
        for match in found {
            result += text[cursor..<match.range.lowerBound]
            expansions.append(match.snippet.expansion)
            result += placeholder(expansions.count)
            cursor = match.range.upperBound
        }
        result += text[cursor...]
        return (result, expansions)
    }

    /// Puts the expansions back. Nil when any placeholder is missing, repeated or mangled —
    /// the caller then redoes the cleanup with the rules, which never touch placeholders.
    public static func restore(_ text: String, expansions: [String]) -> String? {
        // Checked before anything is substituted, so an expansion that itself contains "⟦"
        // can't be mistaken for a placeholder. Exactly the expected markers, each once: a
        // marker the model dropped, doubled or invented fails the whole restore.
        guard text.count(where: { $0 == placeholderOpen }) == expansions.count else { return nil }
        var ranges: [Range<String.Index>] = []
        for index in expansions.indices {
            let marker = placeholder(index + 1)
            guard let range = text.range(of: marker),
                  text.range(of: marker, range: range.upperBound..<text.endIndex) == nil else { return nil }
            ranges.append(range)
        }
        var result = text
        // Back to front, so the earlier ranges stay valid.
        for (range, expansion) in zip(ranges, expansions).sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: expansion)
        }
        return result
    }

    public static let placeholderOpen: Character = "⟦"
    public static let placeholderClose: Character = "⟧"

    static func placeholder(_ number: Int) -> String {
        "\(placeholderOpen)\(number)\(placeholderClose)"
    }

    // MARK: - Words

    static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard isWordCharacter(text[index]) else {
                index = text.index(after: index)
                continue
            }
            let start = index
            var end = index
            while end < text.endIndex {
                let character = text[end]
                if isWordCharacter(character) {
                    end = text.index(after: end)
                } else if isApostrophe(character), text.index(after: end) < text.endIndex,
                          isWordCharacter(text[text.index(after: end)]) {
                    // "j'ai", "don't": one word.
                    end = text.index(after: end)
                } else {
                    break
                }
            }
            words.append(Word(range: start..<end, key: fold(String(text[start..<end]))))
            index = end
        }
        return words
    }

    private static func matches(_ trigger: [String], _ spoken: [Word], at start: Int, in text: String) -> Bool {
        for offset in trigger.indices {
            guard spoken[start + offset].key == trigger[offset] else { return false }
            if offset > 0 {
                let gap = text[spoken[start + offset - 1].range.upperBound..<spoken[start + offset].range.lowerBound]
                guard gap.allSatisfy({ $0.isWhitespace || $0 == "," || $0 == "-" }) else { return false }
            }
        }
        return true
    }

    static func fold(_ word: String) -> String {
        word.replacingOccurrences(of: "’", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }
}
