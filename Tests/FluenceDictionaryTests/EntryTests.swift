import Foundation
import Testing

@testable import FluenceDictionary

/// Entries as the app stores them: verbatim values, `dictionary.txt` lines that read back
/// unchanged, and the JSON shape of the history's applied corrections.
struct EntryTests {
    @Test("the initializer and the factories keep every value as given")
    func verbatim() {
        let term = DictionaryEntry.term("  sp  ")
        #expect(term.kind == .term && term.write == "  sp  " && term.hear == "" && term.isEnabled)
        let correction = DictionaryEntry.correction(hear: " Cloud\u{A0}Code ", write: "cafe\u{301} ")
        #expect(correction.kind == .correction && correction.isEnabled)
        #expect(correction.hear.unicodeScalars.elementsEqual(" Cloud\u{A0}Code ".unicodeScalars))
        #expect(correction.write.unicodeScalars.elementsEqual("cafe\u{301} ".unicodeScalars))
        #expect(DictionaryEntry.term("a").id != DictionaryEntry.term("a").id)
    }

    @Test("equality covers all five properties, the id included")
    func equality() {
        #expect(DictionaryEntry.term("a") != DictionaryEntry.term("a"))
        let id = UUID()
        let on = DictionaryEntry(id: id, kind: .term, write: "a")
        #expect(on == DictionaryEntry(id: id, kind: .term, write: "a"))
        #expect(on.hashValue == DictionaryEntry(id: id, kind: .term, write: "a").hashValue)
        #expect(on != DictionaryEntry(id: id, kind: .term, write: "a", isEnabled: false))
    }

    @Test("dictionary.txt lines, byte for byte", arguments: [
        (DictionaryEntry.term("Anthropic"), "Anthropic"),
        (DictionaryEntry.correction(hear: "cloud code", write: "Claude Code"), "cloud code -> Claude Code"),
        (DictionaryEntry(kind: .correction, write: "W", hear: "h", isEnabled: false), "# off: h -> W"),
        (DictionaryEntry(kind: .term, write: "T", hear: "ignored", isEnabled: false), "# off: T"),
        (DictionaryEntry.term("  sp  "), "  sp  "),
        (DictionaryEntry.correction(hear: "", write: ""), " -> "),
        (DictionaryEntry.correction(hear: "a\nb", write: "c # d"), "a\nb -> c # d"),
    ])
    func fileLine(entry: DictionaryEntry, line: String) {
        #expect(Array(entry.fileLine.utf8) == Array(line.utf8))
    }

    @Test("an applied correction is stored as from, to and count")
    func appliedCorrectionJSON() throws {
        let decoded = try JSONDecoder().decode(AppliedCorrection.self, from: Data(#"{"count": 1, "to": "Claude Code", "from": "CloudCode", "extra": true}"#.utf8))
        #expect(decoded == AppliedCorrection(from: "CloudCode", to: "Claude Code", count: 1))

        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["from", "to", "count"])
        #expect(object["count"] as? Int == 1)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppliedCorrection.self, from: Data(#"{"from": "a", "to": "b"}"#.utf8))
        }
    }

    @Test("an entry's JSON has its five keys, all required, and a lower-case kind")
    func entryJSON() throws {
        let json = #"{"id": "00000000-0000-0000-0000-00000000000a", "kind": "correction", "write": "W", "hear": "H", "isEnabled": false, "extra": 1}"#
        let entry = try JSONDecoder().decode(DictionaryEntry.self, from: Data(json.utf8))
        #expect(entry == DictionaryEntry(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")),
                                         kind: .correction, write: "W", hear: "H", isEnabled: false))

        let encoded = try JSONEncoder().encode(entry)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["id", "kind", "write", "hear", "isEnabled"])
        #expect(object["kind"] as? String == "correction")
        #expect(object["id"] as? String == "00000000-0000-0000-0000-00000000000A")

        for broken in [
            #"{"id": "00000000-0000-0000-0000-000000000001", "kind": "Term", "write": "W", "hear": "", "isEnabled": true}"#,
            #"{"id": "00000000-0000-0000-0000-000000000001", "kind": "term", "write": "W", "isEnabled": true}"#,
        ] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(DictionaryEntry.self, from: Data(broken.utf8))
            }
        }
    }
}
