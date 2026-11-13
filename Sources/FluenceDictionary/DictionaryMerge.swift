import Foundation

extension DictionaryEntry {
    /// What two entries share when they are the same entry: what is heard and what is written,
    /// lower-cased.
    public var mergeKey: String { "\(hear.lowercased())->\(write.lowercased())" }

    /// The `candidates` that `existing` lacks, compared on what is heard and what is written,
    /// case-insensitively; a candidate listed twice is returned once. Used by the « Lexique
    /// Tech » button, which says how many entries it added (FLU-17).
    public static func missing(_ candidates: [DictionaryEntry], from existing: [DictionaryEntry]) -> [DictionaryEntry] {
        var seen = Set(existing.map(\.mergeKey))
        return candidates.filter { seen.insert($0.mergeKey).inserted }
    }
}

extension TechLexicon {
    /// The lexicon entries `entries` lacks, except those the user removed (`declined` holds
    /// their `mergeKey`): « Lexique Tech » never puts back what was deleted on purpose (FLU-138).
    public static func missing(from entries: [DictionaryEntry], declined: Set<String>) -> [DictionaryEntry] {
        DictionaryEntry.missing(defaultEntries.filter { !declined.contains($0.mergeKey) }, from: entries)
    }

    /// The keys of the lexicon's own entries among `removed`, to remember as declined.
    public static func declinedKeys(_ removed: [DictionaryEntry]) -> Set<String> {
        Set(removed.map(\.mergeKey)).intersection(defaultEntries.map(\.mergeKey))
    }
}
