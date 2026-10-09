import Foundation
import Testing

@testable import FluenceDictionary

/// The spellings handed to a speech engine: which entries give one, in what order, how many.
struct BiasPhraseTests {
    private func switchedOff(_ spelling: String) -> DictionaryEntry {
        DictionaryEntry(kind: .term, write: spelling, isEnabled: false)
    }

    private func bias(_ dictionary: [DictionaryEntry]) -> [String] {
        DictionaryCorrector.biasPhrases(from: dictionary)
    }

    private func bias(_ dictionary: [DictionaryEntry], lexicon: Set<String>) -> [String] {
        DictionaryCorrector.biasPhrases(from: dictionary, seeded: lexicon)
    }

    @Test("spellings are trimmed; both kinds count, hear never does; blanks and switched-off entries are skipped")
    func spellings() {
        let dictionary: [DictionaryEntry] = [
            .term(" Postgres\t"), .term("POSTGRES"), .correction(hear: "vue j s", write: "Vue.js"), .term(""),
            .term("\n"), switchedOff("Caché"), .term("vue.JS"), .correction(hear: "red is", write: "  Redis "),
        ]
        #expect(bias(dictionary) == ["Postgres", "Vue.js", "Redis"])
        #expect(bias([.term("\r\nTerraform\r\n")]) == ["Terraform"])
        #expect(bias([]).isEmpty)
    }

    @Test("forty at most, and switched-off entries leave their place to others")
    func limit() {
        #expect(DictionaryCorrector.biasLimit == 40)
        let names = (1...130).map { DictionaryEntry.term("Nom\($0)") }
        #expect(bias(names) == (1...40).map { "Nom\($0)" })
        let sprinkled = names.enumerated().flatMap { index, entry in
            index.isMultiple(of: 9) ? [switchedOff("Off\(index)"), entry] : [entry]
        }
        #expect(bias(sprinkled) == (1...40).map { "Nom\($0)" })
    }

    @Test("one spelling per word: canonical forms and case collapse, accents and ß do not")
    func sameWord() {
        let composed = bias([.term("Ren\u{E9}"), .term("Rene\u{301}"), .term("RENÉ")])
        #expect(composed.map { Array($0.unicodeScalars) } == [Array("Ren\u{E9}".unicodeScalars)])
        #expect(bias([.term("Maß"), .term("MASS")]) == ["Maß", "MASS"])
        #expect(bias([.term("Noël"), .term("Noel")]) == ["Noël", "Noel"])
    }

    @Test("with a lexicon: the user's entries newest first, then the lexicon in its order, forty at most")
    func lexiconAfterUser() {
        let lexicon = (0..<60).map { DictionaryEntry.term("Lib\($0)") }
        let dictionary = Array(lexicon[..<30]) + [.term("Aiguille")] + Array(lexicon[30...])
            + [.correction(hear: "pas cal", write: "Pascal"), .term("Chamonix")]
        #expect(bias(dictionary, lexicon: Set(lexicon.map(\.write)))
            == ["Chamonix", "Pascal", "Aiguille"] + (0..<37).map { "Lib\($0)" })
    }

    @Test("an entry spelled like a lexicon word, in any case and of any kind, joins the lexicon")
    func lexiconMembership() {
        let dictionary: [DictionaryEntry] = [
            .term("Rust"), .term("Mine1"), .correction(hear: "go lang", write: "go"), .term("Go"),
            switchedOff("Mine2"), .term("Mine3"),
        ]
        #expect(bias(dictionary, lexicon: ["Rust", "Go"]) == ["Mine3", "Mine1", "Rust", "go"])
    }

    @Test("lexicon spellings are only lower-cased, while entries are trimmed as well")
    func lexiconComparison() {
        // " Nix" is not trimmed, so "Nix" stays the user's and keeps its place among them.
        #expect(bias([.term("Zig"), .term("Nix"), .term("Odin")], lexicon: [" Nix"]) == ["Odin", "Nix", "Zig"])
        // "  Nix " is trimmed, so it is the lexicon's and goes last.
        #expect(bias([.term("Zig"), .term("  Nix "), .term("Odin")], lexicon: ["NIX"]) == ["Odin", "Zig", "Nix"])
        #expect(bias([.term("Un"), .term("Deux"), .term("Trois")], lexicon: []) == ["Trois", "Deux", "Un"])
        // Between the user's own duplicates, the newest wins.
        #expect(bias([.term("Lua"), .term("Elm"), .term("ELM")], lexicon: ["lua"]) == ["ELM", "Lua"])
    }
}
