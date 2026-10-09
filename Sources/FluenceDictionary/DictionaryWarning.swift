import Foundation

/// A hint that a correction may fire where the user did not mean it, or never do anything.
/// It never blocks the entry. The app writes its own French text from `kind` and `trigger`.
public struct DictionaryWarning: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// The trigger is one everyday word: every use of it is rewritten.
        case ordinaryWord
        /// The trigger is one word of three characters or fewer: it will match often.
        case veryShort
        /// `write` is the trigger again, up to case: the entry changes nothing.
        case rewritesToItself
    }

    /// The message, which differs from one kind to the next: SwiftUI lists warnings by it.
    public var id: String { message }
    /// An English sentence naming the trigger between curly quotes.
    public let message: String
    public var kind: Kind
    /// The entry's `hear`, trimmed, in its own case.
    public var trigger: String

    private init(_ kind: Kind, trigger: String) {
        self.kind = kind
        self.trigger = trigger
        switch kind {
        case .ordinaryWord:
            message = "“\(trigger)” is an everyday word: it will be rewritten every time it is said, not only when you mean it. A longer phrase is safer."
        case .veryShort:
            message = "“\(trigger)” is very short, so it will turn up often inside other speech. A longer phrase is safer."
        case .rewritesToItself:
            message = "This entry turns “\(trigger)” into itself, so it never changes anything."
        }
    }

    /// The hints for one entry: at most one about the trigger's word (everyday or very short),
    /// then one if it rewrites to itself. Terms get none; a disabled correction is still checked.
    public static func check(_ entry: DictionaryEntry) -> [DictionaryWarning] {
        entry.warnedTrigger.map { trigger in
            [wordHint(for: trigger), selfHint(for: trigger, write: entry.write)]
                .compactMap { $0 }
                .map { DictionaryWarning($0, trigger: trigger) }
        } ?? []
    }

    /// About the trigger as one word: everyday, or three characters or fewer. A trigger of
    /// several words, split at spaces and hyphens only, gets no word hint.
    private static func wordHint(for trigger: String) -> Kind? {
        let words = trigger.lowercased().split { $0 == " " || $0 == "-" }
        guard words.count == 1, let word = words.first.map(String.init) else { return nil }
        if OrdinaryWords.all.contains(word) { return .ordinaryWord }
        return word.count <= 3 ? .veryShort : nil
    }

    /// Foundation's comparison of the whole strings: canonical forms are equal, case folds
    /// fully (ß and ss), accents count, and a hyphen is not a space.
    private static func selfHint(for trigger: String, write: String) -> Kind? {
        write.trimmed.caseInsensitiveCompare(trigger) == .orderedSame ? .rewritesToItself : nil
    }
}

private extension DictionaryEntry {
    /// The trigger a warning is about: `hear` trimmed, in its own case. Nil for a term, which
    /// rewrites nothing, and for a blank trigger, which never fires.
    var warnedTrigger: String? {
        switch kind {
        case .term:
            return nil
        case .correction:
            let heard = hear.trimmed
            return heard.isEmpty ? nil : heard
        }
    }
}
