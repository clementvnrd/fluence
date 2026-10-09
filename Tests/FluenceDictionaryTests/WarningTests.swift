import Foundation
import Testing

@testable import FluenceDictionary

/// Hints on a correction's trigger: which ones, in what order, about which trigger.
struct WarningTests {
    private func hints(_ hear: String, _ write: String) -> [DictionaryWarning.Kind] {
        DictionaryWarning.check(.correction(hear: hear, write: write)).map(\.kind)
    }

    @Test("what one correction is warned about", arguments: [
        // One everyday word, alone or padded; with a self-rewrite, the word hint comes first.
        ("lien", "LinkedIn", [DictionaryWarning.Kind.ordinaryWord]),
        ("  Fichier \n", "File", [.ordinaryWord]),
        ("nuage", "Nuage", [.ordinaryWord, .rewritesToItself]),
        ("et", "ET", [.ordinaryWord, .rewritesToItself]),
        ("lien", "", [.ordinaryWord]),
        // One word of three characters or fewer, grapheme clusters counted, NFC or NFD alike.
        ("s3", "S3", [.veryShort, .rewritesToItself]),
        ("gke", "GKE", [.veryShort, .rewritesToItself]),
        ("xz", "7z", [.veryShort]),
        ("q", "queue", [.veryShort]),
        ("\u{E7}\u{E0}\u{E9}", "X", [.veryShort]),
        ("c\u{327}a\u{300}e\u{301}", "X", [.veryShort]),
        ("jwtz", "JWT", []),
        // Words split at spaces and hyphens only, never at a tab.
        ("post gres", "Postgres", []),
        ("le nuage", "iCloud", []),
        ("nuage-", "iCloud", [.ordinaryWord]),
        ("-gke-", "GKE", [.veryShort]),
        ("k-s", "Kafka Streams", []),
        ("vue\tjs", "Vue.js", []),
        ("\tgke\t", "x", [.veryShort]),
        // The whole write against the whole trigger: case folds fully, accents and hyphens count.
        ("Redis", "  redis\n", [.rewritesToItself]),
        ("réseau", "RE\u{301}SEAU", [.rewritesToItself]),
        ("maße", "MASSE", [.rewritesToItself]),
        ("type script", "Type-Script", []),
        ("reseau", "Réseau", []),
        (" \n ", "X", []),
    ])
    func hintsFor(hear: String, write: String, expected: [DictionaryWarning.Kind]) {
        #expect(hints(hear, write) == expected)
    }

    @Test("a term is never warned about; a switched-off correction still is")
    func onlyCorrections() {
        #expect(DictionaryWarning.check(.term("nuage")).isEmpty)
        #expect(DictionaryWarning.check(DictionaryEntry(kind: .term, write: "Nuage", hear: "nuage")).isEmpty)
        let switchedOff = DictionaryEntry(kind: .correction, write: "&", hear: "et", isEnabled: false)
        #expect(DictionaryWarning.check(switchedOff).map(\.kind) == [.ordinaryWord])
    }

    @Test("each hint carries the trigger trimmed, in its own case")
    func triggerAsTyped() {
        #expect(DictionaryWarning.check(.correction(hear: "\n Nuage\t", write: "x")).map(\.trigger) == ["Nuage"])
        #expect(DictionaryWarning.check(.correction(hear: "nuage-", write: "x")).map(\.trigger) == ["nuage-"])
        #expect(DictionaryWarning.check(.correction(hear: "\tGke\t", write: "gke")).map(\.trigger) == ["Gke", "Gke"])
    }

    @Test("a message quotes its trigger, is the hint's id, and differs from one kind to the next")
    func messages() {
        let all = DictionaryWarning.check(.correction(hear: "et", write: "Et"))
            + DictionaryWarning.check(.correction(hear: "xz", write: "7z"))
        #expect(all.map(\.kind) == [.ordinaryWord, .rewritesToItself, .veryShort])
        for hint in all {
            #expect(hint.message.contains("\u{201C}\(hint.trigger)\u{201D}"))
            #expect(hint.id == hint.message)
        }
        #expect(Set(all.map(\.id)).count == all.count)
        let pair = DictionaryWarning.check(.correction(hear: "gke", write: "GKE"))
        #expect(pair.count == 2 && pair[0].id != pair[1].id)
    }

    @Test("the everyday words: English and French, lower case NFC, each listed once")
    func everydayWordList() {
        let set = OrdinaryWords.all
        #expect((150...250).contains(set.count))
        #expect(OrdinaryWords.english.count + OrdinaryWords.french.count == set.count)
        #expect(set.allSatisfy { $0 == $0.lowercased() && $0 == $0.precomposedStringWithCanonicalMapping })
        #expect(set.isSuperset(of: ["lien", "nuage", "fichier", "et", "le"]))
    }

    @Test("cloud and code are flagged words, and so are a and the (D3)")
    func requiredEverydayWords() {
        for word in ["cloud", "code", "a", "the"] {
            #expect(OrdinaryWords.all.contains(word), "\(word) must warn as an everyday word")
        }
    }

    @Test("short tech tokens used in these tests are not everyday words")
    func tokensStayOut() {
        // D3 names the first four; the rest are this file's own examples.
        let tokens = ["qx", "k8s", "z", "abcd", "s3", "gke", "xz", "q", "jwtz", "réseau", "reseau", "maße", "redis"]
        #expect(OrdinaryWords.all.isDisjoint(with: tokens))
    }
}
