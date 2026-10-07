import Foundation

/// A task someone agreed to do.
public struct ActionDraft: Sendable, Hashable, Codable {
    public var text: String
    public var owner: String?
    public var due: String?

    public init(text: String, owner: String? = nil, due: String? = nil) {
        self.text = text
        self.owner = owner
        self.due = due
    }
}

/// A verbatim line worth keeping, with where it was said.
public struct QuoteDraft: Sendable, Hashable, Codable {
    /// `mm:ss` (or `h:mm:ss`), as printed in the transcript.
    public var timestamp: String
    public var speaker: String
    public var text: String

    public init(timestamp: String, speaker: String, text: String) {
        self.timestamp = timestamp
        self.speaker = speaker
        self.text = text
    }
}

/// What the map step extracts from one chunk.
public struct PartialNotes: Sendable, Hashable, Codable {
    public var recap: [String]
    public var actionItems: [ActionDraft]
    public var decisions: [String]
    public var openQuestions: [String]
    public var quotes: [QuoteDraft]

    public init(
        recap: [String] = [],
        actionItems: [ActionDraft] = [],
        decisions: [String] = [],
        openQuestions: [String] = [],
        quotes: [QuoteDraft] = []
    ) {
        self.recap = recap
        self.actionItems = actionItems
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.quotes = quotes
    }

    public var isEmpty: Bool {
        recap.isEmpty && actionItems.isEmpty && decisions.isEmpty && openQuestions.isEmpty && quotes.isEmpty
    }
}

/// What the reduce step writes: the final notes, before they become `MeetingNotes`.
public struct FinalNotesDraft: Sendable, Hashable, Codable {
    public var recap: String
    public var nextSteps: [ActionDraft]
    public var decisions: [String]
    public var openQuestions: [String]

    public init(recap: String, nextSteps: [ActionDraft] = [], decisions: [String] = [], openQuestions: [String] = []) {
        self.recap = recap
        self.nextSteps = nextSteps
        self.decisions = decisions
        self.openQuestions = openQuestions
    }

    public var isEmpty: Bool {
        recap.isEmpty && nextSteps.isEmpty && decisions.isEmpty && openQuestions.isEmpty
    }
}
