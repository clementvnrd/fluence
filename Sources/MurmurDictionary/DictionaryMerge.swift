import Foundation

extension DictionaryEntry {
    /// The `candidates` that `existing` lacks, compared on what is heard and what is written,
    /// case-insensitively; a candidate listed twice is returned once. Used by the « Lexique
    /// Tech » button, which says how many terms it added (FLU-17).
    public static func missing(_ candidates: [DictionaryEntry], from existing: [DictionaryEntry]) -> [DictionaryEntry] {
        func key(_ entry: DictionaryEntry) -> String {
            "\(entry.hear.lowercased())->\(entry.write.lowercased())"
        }
        var seen = Set(existing.map(key))
        return candidates.filter { seen.insert(key($0)).inserted }
    }
}
