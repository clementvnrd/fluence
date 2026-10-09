import Foundation

extension DictionaryCorrector {
    /// The most phrases handed to a speech engine as context.
    public static let biasLimit = 40

    /// The spellings to steer an engine toward: each enabled entry's `write`, trimmed, in the
    /// order given. Blank spellings are skipped, and so is a spelling already taken in another
    /// case; the first one wins. Stops at `biasLimit`.
    public static func biasPhrases(from entries: [DictionaryEntry]) -> [String] {
        var context = BiasContext(capacity: biasLimit)
        context.offer(entries)
        return context.spellings
    }

    /// The same, with the user's own entries first, newest first, and the built-in lexicon after
    /// them, so a long lexicon never pushes the user's words out of the limit (FLU-27). `seeded`
    /// holds the lexicon's spellings; an entry whose trimmed `write` is one of them, in any case,
    /// counts as the lexicon's.
    public static func biasPhrases(from entries: [DictionaryEntry], seeded: Set<String>) -> [String] {
        let builtIn = Set(seeded.map { $0.lowercased() })
        var userEntries: [DictionaryEntry] = []
        var lexiconEntries: [DictionaryEntry] = []
        for entry in entries {
            if builtIn.contains(BiasContext.form(of: entry)) {
                lexiconEntries.append(entry)
            } else {
                userEntries.append(entry)
            }
        }
        var context = BiasContext(capacity: biasLimit)
        context.offer(userEntries.reversed())
        context.offer(lexiconEntries)
        return context.spellings
    }
}

/// The bias list as it fills up: one spelling per lower-cased form, the first one offered wins,
/// and nothing more goes in once it is full.
struct BiasContext {
    let capacity: Int
    private(set) var spellings: [String] = []
    private var forms = Set<String>()

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// What two spellings share when they are the same word in another case.
    static func form(of entry: DictionaryEntry) -> String {
        entry.write.trimmed.lowercased()
    }

    /// Offers each enabled entry's spelling in turn, until the list is full.
    mutating func offer<Entries: Sequence<DictionaryEntry>>(_ entries: Entries) {
        for entry in entries where entry.isEnabled {
            guard spellings.count < capacity else { return }
            let spelling = entry.write.trimmed
            if !spelling.isEmpty, forms.insert(spelling.lowercased()).inserted {
                spellings.append(spelling)
            }
        }
    }
}
