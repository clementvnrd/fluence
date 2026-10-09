import Foundation
import Testing

@testable import FluenceDictionary

/// Corrections the shared vectors leave out on purpose: Unicode folding and spacing, letter and
/// number boundaries beyond ASCII, NFC scalars, tie order, chaining and the report's details.
/// The Windows engine is not known to agree on these, so they are the Swift side's alone.
struct CorrectorTests {
    private func correct(_ input: String, _ rules: [(hear: String, write: String)]) -> (text: String, applied: [AppliedCorrection]) {
        DictionaryCorrector(entries: rules.map { .correction(hear: $0.hear, write: $0.write) }).apply(to: input)
    }

    private func fires(_ hear: String, on input: String) -> Bool {
        !correct(input, [(hear, "X")]).applied.isEmpty
    }

    private func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    private let claude = [(hear: "cloud code", write: "Claude Code")]

    // MARK: Case

    @Test("case folds the ICU way: full folding, ligatures, Kelvin, final sigma", arguments: [
        ("cloud code", "CLOUD CODE"), ("cloud code", "Cloud Code"), ("cloud code", "cLoUd CoDe"),
        ("strasse", "Straße"), ("strasse", "STRASSE"), ("straße", "STRASSE"), ("straße", "strasse"),
        ("straße", "Straße"), ("fi", "\u{FB01}"), ("k", "\u{212A}"),
        ("abσ", "abΣ"), ("abσ", "abσ"), ("abσ", "abς"), ("abς", "abΣ"), ("abς", "abσ"), ("abς", "abς"),
    ])
    func caseFolds(hear: String, input: String) {
        #expect(fires(hear, on: input))
    }

    @Test("no Turkish dotted or dotless I, no fullwidth folding", arguments: [
        ("istanbul", "\u{130}stanbul"), ("istanbul", "\u{131}stanbul"), ("abc", "ＡＢＣ"),
    ])
    func noLocaleOrCompatibilityFolding(hear: String, input: String) {
        #expect(!fires(hear, on: input))
    }

    // MARK: Accents and normalization

    @Test("accents count, but composed and decomposed forms are the same")
    func accentsAndCanonicalForms() {
        #expect(!fires("cafe", on: "café"))
        for hear in ["caf\u{E9}", "cafe\u{301}"] {
            for input in ["caf\u{E9}", "cafe\u{301}"] {
                #expect(fires(hear, on: input))
            }
        }
    }

    @Test("the report's from is the first match, as NFC, in the text's own case")
    func fromIsTheFirstMatch() {
        let decomposed = correct("CAFE\u{301}!", [("café", "Café")])
        #expect(decomposed.applied.map { scalars($0.from) } == [scalars("CAF\u{C9}")])
        #expect(scalars(decomposed.text) == scalars("Café!"))

        let twice = correct("CloudCode then cloud code", claude)
        #expect(twice.applied == [AppliedCorrection(from: "CloudCode", to: "Claude Code", count: 2)])
    }

    @Test("with corrections, the text comes back NFC even when none fires")
    func nfcWhenNothingFires() {
        let result = correct("cafe\u{301}", [("zzz", "Z")])
        #expect(scalars(result.text) == scalars("caf\u{E9}"))
        #expect(result.applied.isEmpty)
    }

    @Test("with no corrections or no text, the text comes back untouched")
    func untouchedWithoutRules() {
        let decomposed = "cafe\u{301}"
        #expect(scalars(DictionaryCorrector(entries: []).apply(to: decomposed).text) == scalars(decomposed))
        #expect(scalars(DictionaryCorrector(entries: [.term("café")]).apply(to: decomposed).text) == scalars(decomposed))
        let empty = correct("", claude)
        #expect(empty.text == "" && empty.applied.isEmpty)
    }

    @Test("what write inserts is kept as typed, even decomposed")
    func writeNotNormalized() {
        let result = correct("a cafe b", [("cafe", "cafe\u{301}")])
        #expect(scalars(result.text) == scalars("a cafe\u{301} b"))
    }

    // MARK: Boundaries

    @Test("a letter or a number next to the match blocks it", arguments: [
        "2cloud code", "cloud code2", "cloud code²", "cloud codeⅫ", "cloud code٣", "cloud codeʰ",
        "écloud code", "cloud codeé", "中cloud code", "\u{1D400}cloud code",
    ])
    func letterOrNumberBlocks(input: String) {
        #expect(correct(input, claude).text == input)
    }

    @Test("anything else is a boundary: punctuation, symbols, emoji, marks, format characters", arguments: [
        ("x_cloud code_y", "x_Claude Code_y"), ("x-cloud code-y", "x-Claude Code-y"),
        ("l'cloud code's", "l'Claude Code's"), ("😀cloud code😀", "😀Claude Code😀"),
        ("@cloud code", "@Claude Code"), ("#cloud code", "#Claude Code"), ("€cloud code", "€Claude Code"),
        ("cloud code/x", "Claude Code/x"), ("cloud code+1", "Claude Code+1"),
        ("\u{301}cloud code", "\u{301}Claude Code"), ("\u{200D}cloud code", "\u{200D}Claude Code"),
        ("\u{200B}cloud code", "\u{200B}Claude Code"), ("cloud code\u{345}", "Claude Code\u{345}"),
        ("\u{345}cloud code", "\u{345}Claude Code"),
    ])
    func otherNeighboursAreBoundaries(input: String, expected: String) {
        #expect(scalars(correct(input, claude).text) == scalars(expected))
    }

    @Test("a combining mark after the match stays after the replacement")
    func enclosingMarkKept() {
        #expect(scalars(correct("cloud code\u{20DD} x", claude).text) == scalars("Claude Code\u{20DD} x"))
    }

    @Test("the boundary is checked around the match, whatever the trigger starts or ends with")
    func boundaryAroundTheMatch() {
        #expect(correct("a.net", [(".net", ".NET")]).text == "a.net")
        #expect(correct(" .net x", [(".net", ".NET")]).text == " .NET x")
        #expect(correct("dot net. dot net", [("dot net.", ".NET")]).text == ".NET dot net")
        #expect(correct("cost $ 5 and 5$", [("$", "USD")]).text == "cost USD 5 and 5$")
    }

    // MARK: Gaps between parts

    @Test("between parts: nothing, or any mix of Unicode whitespace and hyphens", arguments: [
        "CloudCode", "cloud-code", "Cloud-Code", "cloud  code", "cloud - code", "cloud--code",
        "cloud \t code", "cloud\ncode", "cloud\r\ncode", "cloud\u{B}code", "cloud\u{C}code",
        "cloud\u{85}code", "cloud\u{A0}code", "cloud\u{1680}code", "cloud\u{2000}code",
        "cloud\u{200A}code", "cloud\u{2028}code", "cloud\u{2029}code", "cloud\u{202F}code",
        "cloud\u{205F}code", "cloud\u{3000}code",
    ])
    func gapCharacters(input: String) {
        #expect(correct(input, claude).text == "Claude Code")
    }

    @Test("dashes, soft hyphens, zero-width and other look-alikes are not gaps", arguments: [
        "cloud–code", "cloud\u{2011}code", "cloud_code", "cloud.code", "cloud\u{200B}code",
        "cloud\u{FEFF}code", "cloud\u{AD}code", "cloud\u{2010}code", "cloud\u{2212}code",
    ])
    func notGapCharacters(input: String) {
        #expect(correct(input, claude).text == input)
    }

    @Test("gaps between letters of a spelled-out trigger, and around digits")
    func spelledOutTriggers() {
        for input in ["asap", "a-s-a-p", "a s ap", "ASAP"] {
            #expect(fires("a s a p", on: input))
        }
        #expect(fires("1 to 1", on: "1to1"))
        #expect(fires("1 to 1", on: "1 to 1"))
        #expect(!fires("1 to 1", on: "11 to 1"))
        #expect(fires("type script", on: "typescript"))
        #expect(fires("type script", on: "TYPE-SCRIPT"))
        #expect(!fires("type script", on: "typescripts"))
    }

    @Test("whitespace and hyphens around the match stay outside it")
    func noGapOutsideParts() {
        #expect(correct("cloud code - x", claude).text == "Claude Code - x")
        #expect(correct("  cloud code  ", claude).text == "  Claude Code  ")
    }

    // MARK: Reading a trigger

    @Test("a trigger splits at runs of spaces, hyphens and tabs, and nothing else")
    func triggerParts() {
        #expect(correct("a b", [("a  - b", "X")]).text == "X")
        #expect(correct("foo", [("-foo", "X")]).text == "X")
        #expect(correct("foo", [("foo-", "X")]).text == "X")
        #expect(correct("cloud code", [("cloud\tcode", "X")]).text == "X")
        // A no-break space, a newline or an en dash inside a trigger is matched as itself.
        #expect(fires("a\u{A0}b", on: "a\u{A0}b"))
        #expect(!fires("a\u{A0}b", on: "a b"))
        #expect(!fires("a\u{A0}b", on: "ab"))
        #expect(fires("a\nb", on: "x a\nb y"))
        #expect(!fires("a\nb", on: "a b"))
        #expect(fires("a–b", on: "a–b"))
        #expect(!fires("a–b", on: "a-b"))
    }

    @Test("pattern characters in a trigger mean themselves")
    func literalTriggers() {
        #expect(fires("c++", on: "c++") && !fires("c++", on: "c+"))
        #expect(fires("node.js", on: "node.js") && !fires("node.js", on: "nodexjs"))
        #expect(fires(#"\d"#, on: #"a \d b"#) && !fires(#"\d"#, on: "a 5 b"))
        #expect(fires("(beta)", on: "the (beta) build"))
        #expect(fires("$", on: "$"))
        #expect(fires("a*b?[c]{d}|^e", on: " a*b?[c]{d}|^e "))
        #expect(fires("l'api", on: "l'api") && !fires("l'api", on: "l’api"))
    }

    // MARK: Matches and replacement

    @Test("left to right, never overlapping, resuming after each match")
    func leftToRight() {
        #expect(correct("cloud cloud code code", claude).text == "cloud Claude Code code")
        let result = correct("ab ab ab", [("ab ab", "X")])
        #expect(result.text == "X ab")
        #expect(result.applied.map(\.count) == [1])
    }

    @Test("write goes in exactly as typed: no case adaptation, no trimming")
    func writeVerbatim() {
        #expect(correct("GITHUB", [("github", "gitHub")]).text == "gitHub")
        #expect(correct("a x y b", [("x y", " Z ")]).text == "a  Z  b")
    }

    @Test("dollars, backslashes and digits in write are plain text, in the text and in the report")
    func literalWrite() {
        for write in ["$1 $0 \\0", #"C:\dir"#] {
            let result = correct("open it", [("it", write)])
            #expect(result.text == "open \(write)")
            #expect(result.applied.map(\.to) == [write])
        }
    }

    @Test("an empty write deletes the match and nothing else")
    func emptyWriteDeletes() {
        #expect(correct("I um think", [("um", "")]).text == "I  think")
    }

    // MARK: Several corrections

    @Test("a longer trigger runs first and claims its words")
    func longestFirst() {
        let rules = [(hear: "cloud", write: "Claude"), (hear: "cloud code", write: "Claude Code")]
        #expect(correct("cloud code", rules).applied == [AppliedCorrection(from: "cloud code", to: "Claude Code", count: 1)])
        let both = correct("cloud code and cloud", rules)
        #expect(both.text == "Claude Code and Claude")
        #expect(both.applied == [
            AppliedCorrection(from: "cloud code", to: "Claude Code", count: 1),
            AppliedCorrection(from: "cloud", to: "Claude", count: 1),
        ])
    }

    @Test("reports come in the order the corrections ran, longest trigger first")
    func reportOrder() {
        let result = correct("clawed code and whisper flow", [("clawed code", "Claude Code"), ("whisper flow", "Wispr Flow")])
        #expect(result.applied.map(\.to) == ["Wispr Flow", "Claude Code"])
    }

    @Test("later corrections see earlier replacements, so corrections chain")
    func chaining() {
        let chained = correct("cloud code", [("cloud code", "Claude Code"), ("claude", "Clyde")])
        #expect(chained.text == "Clyde Code")
        #expect(chained.applied == [
            AppliedCorrection(from: "cloud code", to: "Claude Code", count: 1),
            AppliedCorrection(from: "Claude", to: "Clyde", count: 1),
        ])
        #expect(correct("cloud code", [("code", "Kode"), ("cloud code", "Claude Code")]).text == "Claude Kode")
        #expect(correct("node js", [("js", "JS"), ("node js", "Node.js")]).text == "Node.JS")
        let reported = correct("abc def", [("abc def", "abc"), ("abc", "X")]).applied
        #expect(reported == [
            AppliedCorrection(from: "abc def", to: "abc", count: 1),
            AppliedCorrection(from: "abc", to: "X", count: 1),
        ])
    }

    @Test("a correction never rescans its own output")
    func noRescan() {
        let result = correct("a b", [("a b", "a b a b")])
        #expect(result.text == "a b a b")
        #expect(result.applied.map(\.count) == [1])
    }

    @Test("equal lengths keep the order of the entries")
    func tiesKeepEntryOrder() {
        #expect(correct("ab cd ef", [("ab cd", "1"), ("cd ef", "2")]).text == "1 ef")
        #expect(correct("ab cd ef", [("cd ef", "2"), ("ab cd", "1")]).text == "ab 2")
        #expect(correct("abc", [("abc", "X"), ("ABC", "Y")]).text == "X")
        #expect(correct("abc", [("ABC", "Y"), ("abc", "X")]).text == "Y")
    }

    @Test("length is counted on the trimmed trigger, so padding never moves a correction ahead")
    func lengthIgnoresPadding() {
        // Trimmed, these are 5 and 5: a tie, so the order of the entries decides.
        #expect(correct("ab cd ef", [("  cd ef  ", "2"), ("ab cd", "1")]).text == "ab 2")
        #expect(correct("ab cd ef", [("ab cd", "1"), ("  cd ef  ", "2")]).text == "1 ef")
        // Padded to 8 but 2 long, "cd" runs after the 5-long "ab cd" and finds nothing left.
        #expect(correct("ab cd", [("      cd", "A"), ("ab cd", "B")]).text == "B")
    }

    @Test("the same trigger twice: the first entry takes every match")
    func duplicateTriggers() {
        let result = correct("foo foo", [("foo", "Bar"), ("foo", "Baz")])
        #expect(result.text == "Bar Bar")
        #expect(result.applied == [AppliedCorrection(from: "foo", to: "Bar", count: 2)])
        let again = correct("foo", [("foo", "FOO"), ("foo", "Baz")])
        #expect(again.text == "Baz")
        #expect(again.applied.count == 2)
    }

    @Test("a firing is reported even when nothing visibly changes, and per correction")
    func reportsEveryFiring() {
        #expect(correct("GitHub and github", [("github", "GitHub")]).applied == [AppliedCorrection(from: "GitHub", to: "GitHub", count: 2)])
        let sameWrite = correct("clawed code and cloud code", [("clawed code", "Claude Code"), ("cloud code", "Claude Code")])
        #expect(sameWrite.applied.map(\.to) == ["Claude Code", "Claude Code"])
        #expect(sameWrite.applied.map(\.count) == [1, 1])
    }

    // MARK: Which entries become corrections

    @Test("only enabled corrections with something in their trigger count")
    func isEmpty() {
        let empty: [[DictionaryEntry]] = [
            [],
            [.term("Anthropic"), DictionaryEntry(kind: .term, write: "Claude", hear: "cloud")],
            [DictionaryEntry(kind: .correction, write: "Claude", hear: "cloud", isEnabled: false)],
            [.correction(hear: "", write: "X")],
            [.correction(hear: "   ", write: "X")],
            [.correction(hear: "---", write: "X")],
            [.correction(hear: " -\t- ", write: "X")],
            [.correction(hear: "\u{200B}\u{200B}", write: "X")],
        ]
        for entries in empty {
            #expect(DictionaryCorrector(entries: entries).isEmpty)
        }
        #expect(!DictionaryCorrector(entries: [.correction(hear: "cloud code", write: "Claude Code")]).isEmpty)
        #expect(!DictionaryCorrector(entries: [.correction(hear: "um", write: "")]).isEmpty)
    }

    @Test("a term rewrites nothing, even with something in its hear")
    func termNeverRewrites() {
        let entries = [DictionaryEntry(kind: .term, write: "Claude", hear: "cloud")]
        #expect(DictionaryCorrector(entries: entries).apply(to: "cloud").text == "cloud")
    }

    // MARK: Robustness

    @Test("odd triggers, writes and texts never trap")
    func neverTraps() {
        let triggers = ["(", ")", "[", "\\", "*", "?", "+", "{", "|", "^", "$", ".", "!!!", "\\E", "\\Q", "#", "\u{301}", "😀", "\r\n", "a\u{0}b"]
        let corrector = DictionaryCorrector(entries: triggers.map { .correction(hear: $0, write: "") })
        #expect(!corrector.isEmpty)
        for input in ["", " ", "\u{301}", "😀😀", "((([[[\\\\", String(repeating: "ab cd ", count: 2_000), "\r\n\r\n"] {
            _ = corrector.apply(to: input)
        }
    }

    @Test("one corrector serves many tasks at once with the same result")
    func concurrentUse() async {
        let corrector = DictionaryCorrector(entries: [.correction(hear: "cloud code", write: "Claude Code"), .correction(hear: "get hub", write: "GitHub")])
        let input = String(repeating: "push cloud code to get hub. ", count: 50)
        let expected = corrector.apply(to: input).text
        let results = await withTaskGroup(of: String.self) { group in
            for _ in 0..<32 {
                group.addTask { corrector.apply(to: input).text }
            }
            return await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(results.count == 32)
        #expect(results.allSatisfy { $0 == expected })
    }
}
