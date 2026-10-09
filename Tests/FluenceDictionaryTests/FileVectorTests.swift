import Foundation
import Testing

@testable import FluenceDictionary

/// One `fileCases` entry of shared/dictionary-test-vectors.json: a raw dictionary.txt and the
/// entries it must give, in order.
struct FileVector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    let expectedEntries: [SharedVector.Rule]

    var testDescription: String { name }

    private struct File: Decodable {
        let fileCases: [FileVector]
    }

    static func all() throws -> [FileVector] {
        guard let url = Bundle.module.url(forResource: "dictionary-test-vectors", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).fileCases
    }
}

/// What the Mac reads from dictionary.txt, against the cases the Windows app runs too.
struct FileVectorTests {
    /// Entries compared without their ids, which are made fresh on every read.
    private struct Seen: Equatable, CustomStringConvertible {
        let kind: DictionaryEntry.Kind
        let write: String
        let hear: String
        let isEnabled: Bool

        var description: String { "\(kind) \(hear)->\(write) \(isEnabled ? "on" : "off")" }
    }

    @Test("the file cases load, and each has its own name")
    func fileShape() throws {
        let cases = try FileVector.all()
        #expect(!cases.isEmpty)
        #expect(Set(cases.map(\.name)).count == cases.count)
    }

    @Test("a shared file case: the entries read from the raw file", arguments: try FileVector.all())
    func fileCase(_ vector: FileVector) {
        let read = DictionaryFileFormat.parse(vector.text).map {
            Seen(kind: $0.kind, write: $0.write, hear: $0.hear, isEnabled: $0.isEnabled)
        }
        let expected = vector.expectedEntries.map {
            Seen(kind: $0.kind == "correction" ? .correction : .term, write: $0.write,
                 hear: $0.hear ?? "", isEnabled: $0.isEnabled ?? true)
        }
        #expect(read == expected)
    }

    @Test("a saved file reads back the same entries, whatever line ending it was read with")
    func roundTrip() {
        let entries: [DictionaryEntry] = [
            .term("Mistral"),
            .correction(hear: "lama index", write: "LlamaIndex"),
            DictionaryEntry(kind: .term, write: "Bun", isEnabled: false),
        ]
        let text = DictionaryFileFormat.render(entries, header: "# en-tête\n")
        #expect(!text.contains("\r"))
        for variant in [text, text.replacingOccurrences(of: "\n", with: "\r\n")] {
            let back = DictionaryFileFormat.parse(variant)
            #expect(back.map(\.fileLine) == entries.map(\.fileLine))
        }
    }

    @Test("lines that are neither comments nor entries are noticed before a save drops them")
    func unreadLines() {
        #expect(!DictionaryFileFormat.hasUnreadLines("# en-tête\n\nRedis\nsupa base -> Supabase\r\n"))
        #expect(DictionaryFileFormat.hasUnreadLines("Redis\n -> sans gauche\n"))
        #expect(DictionaryFileFormat.hasUnreadLines("gauche seule ->\n"))
    }
}
