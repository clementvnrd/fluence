import Foundation
import Testing

@testable import FluenceDictionary

/// One case of shared/dictionary-test-vectors.json, with the format's defaults filled in.
struct SharedVector: Decodable, Sendable, CustomTestStringConvertible {
    struct Rule: Decodable, Sendable {
        let kind: String
        let hear: String?
        let write: String
        let isEnabled: Bool?
    }

    struct Report: Decodable, Hashable, Sendable {
        let to: String
        let count: Int
    }

    let name: String
    let entries: [Rule]
    let input: String
    let expected: String
    let expectedCorrections: [Report]

    var testDescription: String { name }

    /// The case's dictionary. A kind other than "correction" reads as a term; no `hear` is an
    /// empty one, and no `isEnabled` means enabled.
    var dictionary: [DictionaryEntry] {
        entries.map { rule in
            DictionaryEntry(kind: rule.kind == "correction" ? .correction : .term, write: rule.write,
                            hear: rule.hear ?? "", isEnabled: rule.isEnabled ?? true)
        }
    }

    private struct File: Decodable {
        let version: Int
        let cases: [SharedVector]
    }

    /// Every case of the copy bundled with these tests. A missing or malformed file throws.
    static func all() throws -> [SharedVector] {
        guard let url = Bundle.module.url(forResource: "dictionary-test-vectors", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }
}

/// The contract shared with the Windows app, case by case, then the few promises the app makes
/// on top of corrections: a bounded bias list led by the user's words, and trigger warnings.
struct VectorTests {
    @Test("the shared file loads, holds cases, and names each one differently")
    func fileShape() throws {
        let vectors = try SharedVector.all()
        #expect(!vectors.isEmpty)
        #expect(Set(vectors.map(\.name)).count == vectors.count)
    }

    @Test("a shared case: the text that comes back, and which corrections fired how often", arguments: try SharedVector.all())
    func sharedCase(_ vector: SharedVector) {
        let outcome = DictionaryCorrector(entries: vector.dictionary).apply(to: vector.input)
        #expect(outcome.text == vector.expected)
        // The order of the reports is not part of the contract: compare them sorted.
        let fired = outcome.applied.map { SharedVector.Report(to: $0.to, count: $0.count) }
        #expect(fired.sorted(by: Self.byTarget) == vector.expectedCorrections.sorted(by: Self.byTarget))
    }

    private static func byTarget(_ lhs: SharedVector.Report, _ rhs: SharedVector.Report) -> Bool {
        (lhs.to, lhs.count) < (rhs.to, rhs.count)
    }

    @Test("a long list of terms is cut at the limit, each word once whatever its case")
    func biasListIsBounded() {
        let terms = (1...130).flatMap { n -> [DictionaryEntry] in
            n.isMultiple(of: 3) ? [.term("Mot\(n)"), .term("mot\(n)")] : [.term("Mot\(n)")]
        }
        let context = DictionaryCorrector.biasPhrases(from: terms)
        #expect(context.count == DictionaryCorrector.biasLimit)
        #expect(Set(context.map { $0.lowercased() }).count == context.count)
        #expect(context.last == "Mot40")
    }

    @Test("the user's own spellings lead the list, even behind a long lexicon (FLU-27)")
    func userSpellingsFirst() {
        let lexicon = (1...70).map { DictionaryEntry.term("Outil\($0)") }
        let dictionary = lexicon + [.term("Orsay"), .correction(hear: "zoo keeper", write: "ZooKeeper")]
        let led = DictionaryCorrector.biasPhrases(from: dictionary, seeded: Set(lexicon.map(\.write)))
        #expect(led.count == DictionaryCorrector.biasLimit)
        #expect(led.starts(with: ["ZooKeeper", "Orsay", "Outil1"]))
        #expect(led.last == "Outil38")
        // Without the lexicon set, the 70 lexicon words fill the list first.
        #expect(!DictionaryCorrector.biasPhrases(from: dictionary).contains("Orsay"))
    }

    @Test("switched-off entries give the engine nothing")
    func switchedOffNotBiased() {
        let dictionary = [
            DictionaryEntry(kind: .term, write: "Éteint", isEnabled: false),
            .term("Allumé"),
            DictionaryEntry(kind: .correction, write: "Pause", hear: "pose", isEnabled: false),
        ]
        #expect(DictionaryCorrector.biasPhrases(from: dictionary) == ["Allumé"])
    }

    @Test("a French everyday word as a trigger is flagged, and the hint names it")
    func everydayTriggerFlagged() {
        let hints = DictionaryWarning.check(.correction(hear: "lien", write: "LinkedIn"))
        #expect(hints.map(\.kind) == [.ordinaryWord])
        #expect(hints.map(\.trigger) == ["lien"])
    }

    @Test("a two-letter trigger turned into its own capitals gets both hints, the word one first")
    func shortSelfRewrite() {
        #expect(DictionaryWarning.check(.correction(hear: "vm", write: "VM")).map(\.kind) == [.veryShort, .rewritesToItself])
    }

    @Test("a distinctive two-word trigger gets no hint")
    func distinctiveTriggerQuiet() {
        #expect(DictionaryWarning.check(.correction(hear: "kuber netes", write: "Kubernetes")).isEmpty)
    }
}
