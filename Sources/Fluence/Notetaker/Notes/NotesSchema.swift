import FluenceNotesCore
import FoundationModels

// The shapes the on-device model fills in (guided generation).
//
// These conform to `Generable` by hand rather than through `@Generable`/`@Guide`. The
// conformance is exactly what the macro would generate — a schema with described
// properties, plus conversion from and to `GeneratedContent` — but written out it can be
// type-checked on a machine without Xcode (the Command Line Tools ship without the
// FoundationModelsMacros plugin), and the property order, which is the order the model
// writes in, is visible. If Xcode is available, swapping these for `@Generable` structs with
// the same property names and descriptions is behaviour-neutral.

/// A task someone agreed to do.
struct ActionOutput: Generable, Sendable {
    var text: String
    var owner: String?
    var due: String?

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "A task someone agreed to do.", properties: [
            .init(name: "text", description: "The task, starting with a verb.", type: String.self),
            .init(
                name: "owner",
                description: "Who does it, as named in the transcript. Omit when nobody was named.",
                type: String?.self
            ),
            .init(
                name: "due",
                description: "The deadline as it was said. Omit when none was said.",
                type: String?.self
            ),
        ])
    }

    init(_ content: GeneratedContent) throws {
        text = try content.value(String.self, forProperty: "text")
        owner = try content.value(String?.self, forProperty: "owner")
        due = try content.value(String?.self, forProperty: "due")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["text": text, "owner": owner, "due": due])
    }

    var draft: ActionDraft { ActionDraft(text: text, owner: owner, due: due) }
}

/// A sentence worth keeping word for word.
struct QuoteOutput: Generable, Sendable {
    var time: String
    var speaker: String
    var text: String

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "A sentence copied exactly from the transcript.", properties: [
            .init(name: "time", description: "The mm:ss time of its transcript line.", type: String.self),
            .init(name: "speaker", description: "The speaker of that line.", type: String.self),
            .init(name: "text", description: "The words, copied exactly.", type: String.self),
        ])
    }

    init(_ content: GeneratedContent) throws {
        time = try content.value(String.self, forProperty: "time")
        speaker = try content.value(String.self, forProperty: "speaker")
        text = try content.value(String.self, forProperty: "text")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["time": time, "speaker": speaker, "text": text])
    }

    var draft: QuoteDraft { QuoteDraft(timestamp: time, speaker: speaker, text: text) }
}

/// The map step: what one part of the transcript contains.
struct ChunkExtraction: Generable, Sendable {
    var recap: [String]
    var actionItems: [ActionOutput]
    var decisions: [String]
    var openQuestions: [String]
    var quotes: [QuoteOutput]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Notes extracted from one part of a meeting transcript.", properties: [
            .init(
                name: "recap",
                description: "Short points on what was discussed, in order.",
                type: [String].self,
                guides: [.maximumCount(NotesMerger.maxRecapPoints)]
            ),
            .init(
                name: "actionItems",
                description: "Tasks someone agreed to do.",
                type: [ActionOutput].self,
                guides: [.maximumCount(NotesMerger.maxActions)]
            ),
            .init(
                name: "decisions",
                description: "What was agreed or decided.",
                type: [String].self,
                guides: [.maximumCount(NotesMerger.maxDecisions)]
            ),
            .init(
                name: "openQuestions",
                description: "Questions raised and left unanswered.",
                type: [String].self,
                guides: [.maximumCount(NotesMerger.maxQuestions)]
            ),
            .init(
                name: "quotes",
                description: "At most three notable sentences, copied exactly.",
                type: [QuoteOutput].self,
                guides: [.maximumCount(NotesMerger.maxQuotes)]
            ),
        ])
    }

    init(_ content: GeneratedContent) throws {
        recap = try content.value([String].self, forProperty: "recap")
        actionItems = try content.value([ActionOutput].self, forProperty: "actionItems")
        decisions = try content.value([String].self, forProperty: "decisions")
        openQuestions = try content.value([String].self, forProperty: "openQuestions")
        quotes = try content.value([QuoteOutput].self, forProperty: "quotes")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "recap": recap,
            "actionItems": actionItems,
            "decisions": decisions,
            "openQuestions": openQuestions,
            "quotes": quotes,
        ])
    }

    var partial: PartialNotes {
        PartialNotes(
            recap: recap,
            actionItems: actionItems.map(\.draft),
            decisions: decisions,
            openQuestions: openQuestions,
            quotes: quotes.map(\.draft)
        )
    }
}

/// The reduce (or single-pass) step: the notes the user reads.
struct FinalNotesOutput: Generable, Sendable {
    var recap: String
    var nextSteps: [ActionOutput]
    var decisions: [String]
    var openQuestions: [String]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "The final notes of a meeting.", properties: [
            .init(
                name: "recap",
                description: "Three to five sentences of prose: what the meeting was about and what came out of it.",
                type: String.self
            ),
            .init(
                name: "nextSteps",
                description: "Tasks to do after the meeting, each starting with a verb, with owner and due date when said.",
                type: [ActionOutput].self,
                guides: [.maximumCount(NotesMerger.maxActions)]
            ),
            .init(
                name: "decisions",
                description: "What was agreed or decided.",
                type: [String].self,
                guides: [.maximumCount(NotesMerger.maxDecisions)]
            ),
            .init(
                name: "openQuestions",
                description: "Questions still unanswered at the end.",
                type: [String].self,
                guides: [.maximumCount(NotesMerger.maxQuestions)]
            ),
        ])
    }

    init(_ content: GeneratedContent) throws {
        recap = try content.value(String.self, forProperty: "recap")
        nextSteps = try content.value([ActionOutput].self, forProperty: "nextSteps")
        decisions = try content.value([String].self, forProperty: "decisions")
        openQuestions = try content.value([String].self, forProperty: "openQuestions")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "recap": recap,
            "nextSteps": nextSteps,
            "decisions": decisions,
            "openQuestions": openQuestions,
        ])
    }

    var draft: FinalNotesDraft {
        FinalNotesDraft(recap: recap, nextSteps: nextSteps.map(\.draft), decisions: decisions, openQuestions: openQuestions)
    }
}
