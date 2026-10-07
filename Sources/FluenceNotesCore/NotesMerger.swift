import Foundation

/// Cleans what the model returns, merges the map results, and renders them for the reduce
/// step.
///
/// The cleaning is where "never invent" is enforced in code rather than only asked for in
/// the prompt: an owner who appears nowhere in the meeting is dropped, a quote that is not
/// in the transcript is dropped, and placeholder answers ("None", "N/A", "Aucune") are
/// treated as the empty answers they are.
public enum NotesMerger {
    // Caps keep a chatty answer from flooding the notes and the reduce prompt.
    public static let maxRecapPoints = 8
    public static let maxActions = 12
    public static let maxDecisions = 10
    public static let maxQuestions = 8
    public static let maxQuotes = 3

    // MARK: - Cleaning one chunk's extraction

    /// Trims, drops placeholders and duplicates, and drops what the chunk does not support.
    /// `participants` are the meeting's display names.
    public static func clean(_ partial: PartialNotes, chunk: TranscriptChunk, participants: [String]) -> PartialNotes {
        let source = chunk.text
        let sourceWords = Set(words(source))
        let known = participants + chunk.lines.map(\.speaker)
        return PartialNotes(
            recap: cap(dedupe(partial.recap.compactMap(item)), maxRecapPoints),
            actionItems: cap(dedupeActions(partial.actionItems.compactMap {
                action($0, knownNames: known, sourceWords: sourceWords)
            }), maxActions),
            decisions: cap(dedupe(partial.decisions.compactMap(item)), maxDecisions),
            openQuestions: cap(dedupe(partial.openQuestions.compactMap(item)), maxQuestions),
            quotes: cap(partial.quotes.compactMap { quote($0, in: chunk) }, maxQuotes)
        )
    }

    /// Final notes from the reduce step. `known` is every name the meeting and the map
    /// results mention; `sourceText` is everything the reduce step was given.
    public static func clean(_ draft: FinalNotesDraft, knownNames: [String], sourceText: String) -> FinalNotesDraft {
        let sourceWords = Set(words(sourceText))
        return FinalNotesDraft(
            recap: item(draft.recap) ?? "",
            nextSteps: cap(dedupeActions(draft.nextSteps.compactMap {
                action($0, knownNames: knownNames, sourceWords: sourceWords)
            }), maxActions),
            decisions: cap(dedupe(draft.decisions.compactMap(item)), maxDecisions),
            openQuestions: cap(dedupe(draft.openQuestions.compactMap(item)), maxQuestions)
        )
    }

    // MARK: - Merging chunks

    /// One extraction for the whole meeting, in meeting order, near-duplicates removed.
    public static func merge(_ partials: [PartialNotes]) -> PartialNotes {
        PartialNotes(
            recap: dedupe(partials.flatMap(\.recap)),
            actionItems: dedupeActions(partials.flatMap(\.actionItems)),
            decisions: dedupe(partials.flatMap(\.decisions)),
            openQuestions: dedupe(partials.flatMap(\.openQuestions)),
            quotes: dedupeQuotes(partials.flatMap(\.quotes))
        )
    }

    /// Groups extractions so that each group, rendered, fits `budget`. Used when a long
    /// meeting's merged extractions are too big for one reduce call: each group is first
    /// consolidated on its own.
    public static func batches(
        _ partials: [PartialNotes],
        budget: Int,
        measure: (String) -> Int = TokenEstimate.tokens
    ) -> [[PartialNotes]] {
        var groups: [[PartialNotes]] = []
        var current: [PartialNotes] = []
        for partial in partials {
            let candidate = current + [partial]
            if !current.isEmpty && measure(render(merge(candidate))) > budget {
                groups.append(current)
                current = [partial]
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    // MARK: - Rendering for the reduce prompt

    /// Compact plain text: headed lists, one item per line. Empty sections are omitted.
    public static func render(_ partial: PartialNotes) -> String {
        var sections: [String] = []
        func section(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            sections.append(title + ":\n" + lines.map { "- " + $0 }.joined(separator: "\n"))
        }
        section("Recap points", partial.recap)
        section("Action items", partial.actionItems.map(describe))
        section("Decisions", partial.decisions)
        section("Open questions", partial.openQuestions)
        section("Quotes", partial.quotes.map { "[\($0.timestamp)] \($0.speaker): \"\($0.text)\"" })
        return sections.joined(separator: "\n\n")
    }

    public static func describe(_ action: ActionDraft) -> String {
        var details: [String] = []
        if let owner = action.owner { details.append("owner: \(owner)") }
        if let due = action.due { details.append("due: \(due)") }
        return details.isEmpty ? action.text : "\(action.text) (\(details.joined(separator: "; ")))"
    }

    // MARK: - Items

    /// A list item, trimmed of bullets and quotes; nil when it is empty or a placeholder.
    static func item(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, "-•*–·".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty, !isPlaceholder(text) else { return nil }
        return text
    }

    static func isPlaceholder(_ text: String) -> Bool {
        let key = normalize(text)
        return placeholders.contains(key)
    }

    private static let placeholders: Set<String> = [
        "", "none", "n a", "na", "nil", "null", "unknown", "not specified", "not mentioned",
        "no one", "nobody", "tbd", "unassigned", "nothing", "aucun", "aucune", "rien",
        "inconnu", "inconnue", "non precise", "non precisee", "non specifie", "personne",
        "a definir", "pas de date", "no date",
    ]

    private static func action(_ raw: ActionDraft, knownNames: [String], sourceWords: Set<String>) -> ActionDraft? {
        guard let text = item(raw.text) else { return nil }
        let owner = raw.owner.flatMap(item).flatMap { grounded($0, knownNames: knownNames, sourceWords: sourceWords) }
        let due = raw.due.flatMap(item)
        return ActionDraft(text: text, owner: owner, due: due)
    }

    /// Keeps an owner only when at least one of its words is a participant's name or
    /// appears in the source text. "Marie" for participant "Marie Dupont" stays; a name the
    /// model made up goes.
    static func grounded(_ owner: String, knownNames: [String], sourceWords: Set<String>) -> String? {
        let ownerWords = words(owner).filter { $0.count >= 2 }
        guard !ownerWords.isEmpty else { return nil }
        let nameWords = Set(knownNames.flatMap(words))
        return ownerWords.contains { nameWords.contains($0) || sourceWords.contains($0) } ? owner : nil
    }

    /// Keeps a quote only when it is (nearly) verbatim in the chunk, and stamps it with the
    /// time and speaker of the line it came from rather than trusting the model's.
    static func quote(_ raw: QuoteDraft, in chunk: TranscriptChunk) -> QuoteDraft? {
        let text = raw.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\"“”«»'")))
        let quoteWords = words(text)
        guard quoteWords.count >= 3 else { return nil }
        var best: (line: TranscriptLine, overlap: Double)?
        for line in chunk.lines {
            let lineWords = Set(words(line.text))
            let overlap = Double(quoteWords.filter(lineWords.contains).count) / Double(quoteWords.count)
            if overlap > (best?.overlap ?? 0) { best = (line, overlap) }
        }
        guard let best, best.overlap >= 0.8 else { return nil }
        return QuoteDraft(timestamp: Clock.format(best.line.start), speaker: best.line.speaker, text: text)
    }

    // MARK: - Dedupe

    static func dedupe(_ items: [String]) -> [String] {
        var kept: [String] = []
        for item in items where !kept.contains(where: { isNearDuplicate($0, item) }) {
            kept.append(item)
        }
        return kept
    }

    /// Keeps the first of near-duplicate actions, filling in an owner or due date that only
    /// a later duplicate carried.
    static func dedupeActions(_ actions: [ActionDraft]) -> [ActionDraft] {
        var kept: [ActionDraft] = []
        for action in actions {
            if let index = kept.firstIndex(where: { isNearDuplicate($0.text, action.text) }) {
                if kept[index].owner == nil { kept[index].owner = action.owner }
                if kept[index].due == nil { kept[index].due = action.due }
            } else {
                kept.append(action)
            }
        }
        return kept
    }

    static func dedupeQuotes(_ quotes: [QuoteDraft]) -> [QuoteDraft] {
        var kept: [QuoteDraft] = []
        for quote in quotes where !kept.contains(where: { isNearDuplicate($0.text, quote.text) }) {
            kept.append(quote)
        }
        return kept
    }

    /// Same words, ignoring case, accents and punctuation; or word sets overlapping by 85 %.
    /// Not lower: "Marie sends the contract on Monday" and "Paul sends the contract on
    /// Monday" overlap by 80 % and are two different tasks.
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let (left, right) = (normalize(a), normalize(b))
        if left == right { return true }
        let (x, y) = (Set(left.split(separator: " ")), Set(right.split(separator: " ")))
        guard !x.isEmpty, !y.isEmpty else { return false }
        let jaccard = Double(x.intersection(y).count) / Double(x.union(y).count)
        return jaccard >= 0.85
    }

    /// Lowercased, accents folded, punctuation collapsed to single spaces.
    static func normalize(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func cap<T>(_ items: [T], _ limit: Int) -> [T] {
        Array(items.prefix(limit))
    }
}
