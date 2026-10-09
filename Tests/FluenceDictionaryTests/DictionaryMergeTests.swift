import Foundation
import Testing

@testable import FluenceDictionary

/// The « Lexique Tech » import adds only what the dictionary lacks, and says how many (FLU-17).
struct DictionaryMergeTests {
    let lexicon: [DictionaryEntry] = [
        .term("Kubernetes"),
        .correction(hear: "get hub", write: "GitHub"),
        .term("Swift"),
    ]

    @Test("terms already in the dictionary, in any case, are not added again")
    func onlyMissing() {
        let existing: [DictionaryEntry] = [.term("kubernetes"), .correction(hear: "Get Hub", write: "github")]
        #expect(DictionaryEntry.missing(lexicon, from: existing).map(\.write) == ["Swift"])
    }

    @Test("a dictionary that holds the whole lexicon gets nothing: the second import adds zero")
    func idempotent() {
        let first = DictionaryEntry.missing(lexicon, from: [])
        #expect(first.count == 3)
        #expect(DictionaryEntry.missing(lexicon, from: first).isEmpty)
    }

    @Test("a candidate listed twice is added once")
    func duplicates() {
        #expect(DictionaryEntry.missing(lexicon + [.term("SWIFT")], from: []).count == 3)
    }
}
