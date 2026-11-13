import Foundation
import Testing

@testable import FluenceDictionary

/// dictionary.txt is the user's own hand-edited file: reading it must never make it look empty,
/// and what the app writes must read back as itself (FLU-138).
struct DictionaryFileSafetyTests {
    // MARK: A6-1, encodings

    @Test("a file saved in another encoding still reads, accents included", arguments: [
        String.Encoding.utf8, .utf16, .utf16LittleEndian, .isoLatin1, .windowsCP1252, .macOSRoman,
    ])
    func decodesOtherEncodings(_ encoding: String.Encoding) throws {
        let text = "Ollivault\nprès prod -> préprod\n"
        var bytes = try #require(text.data(using: encoding))
        // A UTF-16 file without its byte-order mark is not guessed; Windows tools write one.
        if encoding == .utf16LittleEndian { bytes = Data([0xFF, 0xFE]) + bytes }
        #expect(DictionaryFileFormat.decode(bytes) == text)
    }

    @Test("a UTF-8 byte-order mark is not part of the first entry")
    func utf8ByteOrderMark() throws {
        let decoded = try #require(DictionaryFileFormat.decode(Data([0xEF, 0xBB, 0xBF]) + Data("Ollivault\n".utf8)))
        #expect(DictionaryFileFormat.parse(decoded).map(\.write) == ["Ollivault"])
    }

    // MARK: A6-10, what a line can hold

    @Test("an entry the file would read back as something else cannot be stored", arguments: [
        DictionaryEntry.term("#general"),
        .term("C->D"),
        .term("# off: x"),
        .correction(hear: "a->b", write: "c"),
        .correction(hear: "#canal", write: "#general"),
        .term("deux\nlignes"),
    ])
    func refusesWhatDoesNotRoundTrip(_ entry: DictionaryEntry) {
        #expect(!DictionaryFileFormat.canStore(entry))
    }

    @Test("ordinary entries, a # inside a word and an arrow in what is written can be stored", arguments: [
        DictionaryEntry.term("Ollivault"),
        .term("C#"),
        .correction(hear: "canal général", write: "#general"),
        .correction(hear: "flèche", write: "a -> b"),
        DictionaryEntry(kind: .term, write: "Bun", isEnabled: false),
    ])
    func acceptsWhatRoundTrips(_ entry: DictionaryEntry) {
        #expect(DictionaryFileFormat.canStore(entry))
    }

    // MARK: A6-15, ids across an outside change

    @Test("an outside change keeps the ids of unchanged lines, so an open edit sheet still saves")
    func reloadKeepsIDs() {
        let before = DictionaryFileFormat.parse("Redis\nsupa base -> Supabase\nRedis\n")
        let after = DictionaryFileFormat.parse("Redis\nPostHog\nsupa base -> Supabase\nRedis\n", keepingIDsOf: before)
        #expect(after.map(\.write) == ["Redis", "PostHog", "Supabase", "Redis"])
        #expect(after[0].id == before[0].id)
        #expect(after[2].id == before[1].id)
        #expect(after[3].id == before[2].id)
        #expect(!before.map(\.id).contains(after[1].id))
    }

    // MARK: A6-14, « Lexique Tech » and deleted entries

    @Test("a lexicon entry the user deleted is not offered again")
    func declinedLexiconEntries() throws {
        let lexicon = TechLexicon.defaultEntries
        let removed = try #require(lexicon.first)
        let declined = TechLexicon.declinedKeys([removed, .term("Mon mot à moi")])
        #expect(declined == [removed.mergeKey])
        let rest = Array(lexicon.dropFirst())
        #expect(TechLexicon.missing(from: rest, declined: declined).isEmpty)
        #expect(TechLexicon.missing(from: rest, declined: []).map(\.mergeKey) == [removed.mergeKey])
    }

    // MARK: A5-10, A6-12, « Scanner un projet… »

    @Test("a project scan proposes the folder, the package and its first 20 dependencies in order, minus what is known")
    func projectVocabulary() throws {
        let dependencies = (1...25).map { "\"dep-\(String(format: "%02d", $0))\": \"1.0\"" }.joined(separator: ", ")
        let json = Data("{\"name\": \"@acme/portail\", \"dependencies\": {\"@scope/zod\": \"3\", \(dependencies)}}".utf8)
        let found = ProjectVocabulary.candidates(folderName: "Projet", packageJSON: json, known: [.term("dep-03")])
        #expect(found.first == "Projet")
        #expect(found.dropFirst().first == "portail")
        // Sorted, so two scans of the same folder agree; zod comes last and is cut.
        #expect(Array(found.dropFirst(2)) == (1...20).map { String(format: "dep-%02d", $0) }.filter { $0 != "dep-03" })
    }

    @Test("names of two letters or fewer are not proposed, and nothing is proposed twice")
    func projectVocabularyFilters() {
        let json = Data("{\"name\": \"projet\", \"dependencies\": {\"ws\": \"1\"}}".utf8)
        #expect(ProjectVocabulary.candidates(folderName: "Projet", packageJSON: json, known: []) == ["Projet"])
    }
}
