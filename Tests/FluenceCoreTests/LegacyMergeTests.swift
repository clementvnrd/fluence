import Foundation
import Testing

@testable import FluenceCore

/// The file-by-file migration from Clement's build (FLU-11). Synthetic fixtures only.
struct LegacyMergeStepTests {
    @Test func nothingToDoWithoutALegacyFile() {
        #expect(LegacyMerge.step(legacyExists: false, currentExists: false) == .nothing)
        #expect(LegacyMerge.step(legacyExists: false, currentExists: true) == .nothing)
    }

    @Test func movesWhenFluenceLacksTheFile() {
        #expect(LegacyMerge.step(legacyExists: true, currentExists: false) == .move)
    }

    /// The case that used to be skipped: `Fluence/` exists (Whisper models) and so does the
    /// file in it.
    @Test func mergesWhenBothExist() {
        #expect(LegacyMerge.step(legacyExists: true, currentExists: true) == .merge)
    }
}

struct LegacyDictionaryMergeTests {
    private let current = """
        # Fluence dictionary
        #
        Anthropic
        cloud code -> Claude Code

        """

    @Test func appendsOnlyMissingEntries() throws {
        let legacy = """
            # an old header
            anthropic
            Vercel
            cloud code->Claude Code
            # off: whisper flow -> Wispr Flow
            """
        let merged = try #require(LegacyMerge.mergeDictionary(current: current, legacy: legacy))
        #expect(merged.hasPrefix(current))
        let added = merged.dropFirst(current.count).split(separator: "\n").map(String.init)
        #expect(added == ["Vercel", "# off: whisper flow -> Wispr Flow"])
    }

    @Test func returnsNilWhenEverythingIsKnown() {
        #expect(LegacyMerge.mergeDictionary(current: current, legacy: "Anthropic\n# just a comment\n") == nil)
    }

    @Test func addsANewlineBeforeAppending() throws {
        let merged = try #require(LegacyMerge.mergeDictionary(current: "Alpha", legacy: "Beta"))
        #expect(merged == "Alpha\nBeta\n")
    }

    @Test func doesNotDuplicateWithinTheLegacyFile() throws {
        let merged = try #require(LegacyMerge.mergeDictionary(current: "", legacy: "Beta\nbeta\nBETA"))
        #expect(merged == "Beta\n")
    }
}

struct LegacyHistoryImportTests {
    /// A run's identity is its "date|text" — here the line itself, when it starts with "{".
    private func identity(_ line: Data) -> String? {
        let text = String(decoding: line, as: UTF8.self)
        return text.hasPrefix("{") ? text : nil
    }

    @Test func sortsFreshUnreadableAndDuplicateLines() {
        let file = Data("{a}\n{b}\nnot json\n{a}\n\n{c}\n".utf8)
        let plan = LegacyMerge.importHistory(file, alreadySealed: ["{c}"], identity: identity)
        #expect(plan.fresh.map { String(decoding: $0, as: UTF8.self) } == ["{a}", "{b}"])
        #expect(plan.unreadable.map { String(decoding: $0, as: UTF8.self) } == ["not json"])
        #expect(plan.duplicates == 2) // the second {a}, and {c} already sealed
    }

    @Test func emptyFileImportsNothing() {
        let plan = LegacyMerge.importHistory(Data(), alreadySealed: [], identity: identity)
        #expect(plan == LegacyMerge.HistoryImport())
    }

    @Test func blankLinesAreNotUnreadable() {
        let plan = LegacyMerge.importHistory(Data("  \n\r\n{a}\n".utf8), alreadySealed: [], identity: identity)
        #expect(plan.fresh.count == 1)
        #expect(plan.unreadable.isEmpty)
    }
}

struct LegacySnippetImportTests {
    /// The shape Clement's `SnippetStore` wrote with a plain `JSONEncoder`.
    private func legacyJSON() throws -> Data {
        struct Legacy: Encodable {
            var id: UUID
            var cue: String
            var expansion: String
            var isEnabled: Bool
            var createdAt: Date
        }
        return try JSONEncoder().encode([
            Legacy(id: UUID(), cue: "  my calendly ", expansion: "https://example.com/meet", isEnabled: true,
                   createdAt: Date(timeIntervalSinceReferenceDate: 100)),
            Legacy(id: UUID(), cue: "sign off", expansion: "Best,\nAda", isEnabled: false,
                   createdAt: Date(timeIntervalSinceReferenceDate: 200)),
            Legacy(id: UUID(), cue: "   ", expansion: "dropped: no cue", isEnabled: true,
                   createdAt: Date(timeIntervalSinceReferenceDate: 300)),
        ])
    }

    @Test func readsClementsFormat() throws {
        let snippets = try LegacyMerge.snippets(fromLegacyJSON: legacyJSON())
        #expect(snippets.map(\.trigger) == ["my calendly", "sign off"])
        #expect(snippets.map(\.isEnabled) == [true, false])
        #expect(snippets[1].expansion == "Best,\nAda")
        #expect(snippets[0].createdAt == Date(timeIntervalSinceReferenceDate: 100))
    }

    @Test func rejectsAFileInAnotherFormat() {
        #expect(throws: (any Error).self) {
            try LegacyMerge.snippets(fromLegacyJSON: Data("{\"not\": \"a list\"}".utf8))
        }
    }

    @Test func mergeKeepsCurrentAndSkipsSameTrigger() {
        let current = [Snippet(trigger: "My Calendly", expansion: "kept")]
        let imported = [
            Snippet(trigger: "my calendly", expansion: "duplicate trigger"),
            Snippet(trigger: "sign off", expansion: "new"),
        ]
        let merged = LegacyMerge.mergeSnippets(current: current, imported: imported)
        #expect(merged.map(\.expansion) == ["kept", "new"])
    }

    @Test func mergeIsIdempotent() {
        let imported = [Snippet(trigger: "sign off", expansion: "new")]
        let once = LegacyMerge.mergeSnippets(current: [], imported: imported)
        #expect(LegacyMerge.mergeSnippets(current: once, imported: imported) == once)
    }

    @Test func snippetsSealedBeforeIsEnabledDecodeAsEnabled() throws {
        let old = Data(#"[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","trigger":"x","expansion":"y"}]"#.utf8)
        let decoded = try JSONDecoder().decode([Snippet].self, from: old)
        #expect(decoded.first?.isEnabled == true)
    }
}

struct LegacySettingsTests {
    @Test func mapsClementsLanguageValues() {
        #expect(LegacyMerge.dictationLanguage(fromLegacy: "fr-FR") == .french)
        #expect(LegacyMerge.dictationLanguage(fromLegacy: "en-US") == .english)
        #expect(LegacyMerge.dictationLanguage(fromLegacy: "auto") == .auto)
        #expect(LegacyMerge.dictationLanguage(fromLegacy: "system") == .auto)
        #expect(LegacyMerge.dictationLanguage(fromLegacy: "de_DE") == .german)
        #expect(LegacyMerge.dictationLanguage(fromLegacy: "fr") == .french)
    }

    @Test func unknownOrMissingValuesAreNil() {
        #expect(LegacyMerge.dictationLanguage(fromLegacy: nil) == nil)
        #expect(LegacyMerge.dictationLanguage(fromLegacy: "") == nil)
        #expect(LegacyMerge.dictationLanguage(fromLegacy: "klingon") == nil)
    }
}
