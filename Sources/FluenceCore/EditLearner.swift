import Foundation

/// Learns dictionary words from the user's own corrections of dictated text.
///
/// After a dictation is typed, the app re-reads the text field for a short while. If the
/// user fixed a word Fluence wrote ("clod" → "Claude"), the fix is a strong hint that the
/// engine will get that word wrong again — but only for names and jargon. Fixing "there" to
/// "their" teaches nothing a dictionary should hold, so only corrections that look like a
/// proper noun or a term of art become proposals, and a proposal is only ever *offered*:
/// nothing is added without the user saying yes.
public enum EditLearner {
    public struct Proposal: Hashable, Sendable, Identifiable {
        /// What Fluence typed.
        public let heard: String
        /// What the user changed it to.
        public let written: String

        public var id: String { "\(heard)→\(written)" }

        /// Whether to file it as a correction (`heard -> written`) rather than a plain term.
        ///
        /// A correction rewrites every future occurrence of `heard`, which is only safe when
        /// `heard` is not an everyday word: "clod -> Claude" is fine, "cloud -> Claude"
        /// would rewrite every cloud. A multi-word phrase is specific enough on its own.
        public var isCorrection: Bool {
            let sameLetters = SnippetMatcher.fold(heard) == SnippetMatcher.fold(written)
            guard !sameLetters else { return false }
            let words = heard.split(separator: " ")
            return words.count > 1 || (heard.count >= 3 && !EditLearner.isCommon(heard))
        }
    }

    /// Longest term proposed. Past this it is a phrase being rewritten, not a name.
    public static let maximumLength = 40

    // MARK: - Locating the edit

    /// The text now standing where the dictation was inserted, or nil when the field didn't
    /// change there.
    ///
    /// Positions are UTF-16 offsets, as Accessibility reports them. The one changed region
    /// between the two snapshots is found from their common prefix and suffix; an edit that
    /// reaches outside the inserted span is the user writing something else, not correcting
    /// the dictation, and is ignored.
    public static func editedSpan(before: String, after: String, inserted: Range<Int>) -> String? {
        let old = Array(before.utf16)
        let new = Array(after.utf16)
        guard old != new, inserted.lowerBound >= 0, inserted.upperBound <= old.count else { return nil }

        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        let changedStart = prefix
        let changedEnd = old.count - suffix
        guard changedStart >= inserted.lowerBound, changedEnd <= inserted.upperBound else { return nil }

        let end = inserted.upperBound + (new.count - old.count)
        guard end >= inserted.lowerBound, end <= new.count else { return nil }
        return String(decoding: new[inserted.lowerBound..<end], as: UTF16.self)
    }

    // MARK: - Comparing words

    /// What the user's edit of `inserted` into `edited` teaches the dictionary.
    public static func proposals(inserted: String, edited: String) -> [Proposal] {
        let typed = words(inserted)
        let fixed = words(edited)
        guard !typed.isEmpty, !fixed.isEmpty else { return [] }

        var proposals: [Proposal] = []
        for block in replacedBlocks(typed.map(\.text), fixed.map(\.text)) {
            let old = Array(typed[block.old])
            let new = Array(fixed[block.new])
            if old.count == new.count {
                // "cloud code" → "Claude Code": one phrase when every new word is capitalised.
                if old.count > 1, new.allSatisfy({ isNameLike($0.text) }) {
                    add(heard: old.map(\.text).joined(separator: " "),
                        written: new.map(\.text).joined(separator: " "),
                        atSentenceStart: old[0].startsSentence, to: &proposals)
                    continue
                }
                for (before, after) in zip(old, new) {
                    add(heard: before.text, written: after.text, atSentenceStart: before.startsSentence, to: &proposals)
                }
            } else if new.count == 1 {
                // "cloud flare" → "Cloudflare".
                add(heard: old.map(\.text).joined(separator: " "), written: new[0].text,
                    atSentenceStart: old.first?.startsSentence ?? false, to: &proposals)
            } else if old.count == 1 {
                // "claudecode" → "Claude Code".
                add(heard: old[0].text, written: new.map(\.text).joined(separator: " "),
                    atSentenceStart: old[0].startsSentence, to: &proposals)
            }
        }
        return proposals
    }

    private static func add(heard: String, written: String, atSentenceStart: Bool, to proposals: inout [Proposal]) {
        guard heard != written, written.count <= maximumLength, written.count(where: \.isLetter) >= 2 else { return }
        // Addresses, paths and numbers aren't dictionary words.
        guard !written.contains(where: { "@/\\:".contains($0) }), !written.allSatisfy({ !$0.isLetter }) else { return }

        let parts = written.split(separator: " ").map(String.init)
        guard parts.allSatisfy(isNameLike) else { return }
        // Every word common ("The", "Hello"): a capital fixed at the start of a sentence, or
        // an ordinary word, not a name.
        guard !parts.allSatisfy(isCommon) else { return }

        let caseOnly = heard.lowercased() == written.lowercased()
        if caseOnly, atSentenceStart, written == capitalizedFirst(heard) { return }

        let proposal = Proposal(heard: heard, written: written)
        if !proposals.contains(proposal) { proposals.append(proposal) }
    }

    /// Capitalised ("Claude"), all caps ("NASA") or internal capitals ("iPhone", "McKinsey").
    static func isNameLike(_ word: String) -> Bool {
        word.contains { $0.isUppercase }
    }

    static func isCommon(_ word: String) -> Bool {
        commonWords.contains(SnippetMatcher.fold(word))
    }

    private static func capitalizedFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    // MARK: - Diff

    struct Token {
        let text: String
        let startsSentence: Bool
    }

    static func words(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var sentenceStart = true
        var pendingStart = true

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(Token(text: current, startsSentence: pendingStart))
            current = ""
            pendingStart = false
        }

        for character in text {
            if character.isLetter || character.isNumber || character == "'" || character == "’"
                || (character == "-" && !current.isEmpty) {
                if current.isEmpty { pendingStart = sentenceStart; sentenceStart = false }
                current.append(character)
            } else {
                flush()
                if ".!?\n".contains(character) { sentenceStart = true }
            }
        }
        flush()
        // Trailing hyphens and apostrophes are punctuation, not part of the word.
        return tokens.map {
            Token(text: $0.text.trimmingCharacters(in: CharacterSet(charactersIn: "-'’")), startsSentence: $0.startsSentence)
        }.filter { !$0.text.isEmpty }
    }

    /// Runs where the two word lists differ, between anchors of words they share (LCS).
    static func replacedBlocks(_ old: [String], _ new: [String]) -> [(old: Range<Int>, new: Range<Int>)] {
        let n = old.count
        let m = new.count
        // Typed dictations are short; the quadratic table is a few hundred cells.
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = old[i] == new[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var blocks: [(old: Range<Int>, new: Range<Int>)] = []
        var i = 0
        var j = 0
        var blockStart: (Int, Int)?
        func close() {
            if let (si, sj) = blockStart, i > si, j > sj { blocks.append((si..<i, sj..<j)) }
            blockStart = nil
        }
        while i < n, j < m {
            if old[i] == new[j] {
                close()
                i += 1
                j += 1
            } else {
                if blockStart == nil { blockStart = (i, j) }
                if lcs[i + 1][j] >= lcs[i][j + 1] { i += 1 } else { j += 1 }
            }
        }
        if blockStart == nil, i < n || j < m { blockStart = (i, j) }
        i = n
        j = m
        close()
        return blocks
    }

    // MARK: - Common words

    /// Everyday English and French words, folded. A correction *to* one of these is grammar
    /// or spelling, not vocabulary; a correction *from* one is never made into a rewrite rule.
    static let commonWords: Set<String> = Set((english + " " + french).split(separator: " ").map(String.init))

    private static let english = """
        a about above after again against all also am an and any are as at back be because been \
        before being below between both but by can could day did do does doing down during each \
        even every few first for from further get go going good got great had has have having he \
        her here hers him his how i if in into is it its just know last let like little long look \
        made make many may me more most much must my new next no nor not now of off ok okay old on \
        once one only or other our out over own people please right said same say see she should \
        so some still such take than thank thanks that the their them then there these they thing \
        think this those through time to today tomorrow too two under until up us very want was \
        way we well were what when where which while who why will with work would yeah yes yet you \
        your hi hello hey dear best regards monday tuesday wednesday thursday friday saturday \
        sunday january february march april june july august september october november december \
        cloud code mail email call meeting team project report note
        """

    private static let french = """
        a ai alors au aussi aux avec avoir bien bon bonjour bonsoir ca ce cela ces cet cette chez \
        comme comment dans de des deja demain donc du elle elles en encore est et etre fait faire \
        il ils je juste la le les leur lui ma mais me merci mes moi mon ne ni non nous on ou oui \
        par pas pour plus quand que quel quelle qui sa salut se ses si son sont sur ta te tes toi \
        ton tous tout tres tu un une va vos votre vous lundi mardi mercredi jeudi vendredi samedi \
        dimanche janvier fevrier mars avril mai juin juillet aout septembre octobre novembre \
        decembre aujourd'hui hier
        """
}
