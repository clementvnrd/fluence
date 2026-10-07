import Testing

@testable import FluenceCore

struct CleanupGuardTests {
    private func verdict(_ original: String, _ cleaned: String) -> CleanupGuard.Verdict {
        CleanupGuard.evaluate(original: original, cleaned: cleaned)
    }

    // MARK: - What it exists to catch

    @Test func answeredQuestionIsRejected() {
        // "Paris" is the only word nobody said.
        #expect(verdict("what is the capital of france", "The capital of France is Paris.") == .inventedWords(1))
    }

    @Test func inventedNumberIsRejected() {
        guard case .inventedWords = verdict("how many legs does a spider have", "A spider has 8 legs.") else {
            Issue.record("an answer containing a number nobody said must be rejected")
            return
        }
    }

    @Test func droppingHalfTheDictationIsRejected() {
        let spoken = "we need to ship the release on friday and tell the support team about the new pricing page"
        let cleaned = "We need to ship the release on Friday."
        guard case .lengthRatio(let ratio) = verdict(spoken, cleaned) else {
            Issue.record("a cleanup that drops a whole clause must be rejected")
            return
        }
        // Accepted under the old 0.35 floor.
        #expect(ratio > 0.35 && ratio < CleanupGuard.minimumRatio)
    }

    @Test func commentaryIsRejected() {
        // Every word was spoken, but the model has started talking back.
        #expect(verdict("send the report sure", "Sure, send the report.") == .commentary)
    }

    @Test func emptyOutputIsRejected() {
        #expect(verdict("hello there", "") == .empty)
    }

    // MARK: - What it must let through

    @Test func fillerHeavyCleanupIsAccepted() {
        #expect(verdict(
            "so um basically i think we should uh go to the store",
            "I think we should go to the store."
        ) == .accepted)
    }

    @Test func spokenSelfCorrectionIsAccepted() {
        #expect(verdict("let's meet at three no wait four", "Let's meet at four.") == .accepted)
        #expect(verdict("send it tuesday actually wednesday", "Send it Wednesday.") == .accepted)
    }

    @Test func speakerWhoSaysSureIsNotCommentary() {
        #expect(verdict("sure i can do tuesday", "Sure, I can do Tuesday.") == .accepted)
    }

    @Test func numberWordsBecomingDigitsAreNotInvented() {
        #expect(verdict("i need three apples and twenty five oranges", "I need 3 apples and 25 oranges.") == .accepted)
        #expect(verdict("it shipped in twenty twenty six", "It shipped in 2026.") == .accepted)
        #expect(verdict("born in nineteen eighty four", "Born in 1984.") == .accepted)
        #expect(verdict("we hired one thousand people", "We hired 1,000 people.") == .accepted)
        #expect(verdict("about two thousand and five units", "About 2005 units.") == .accepted)
        #expect(verdict("five million users", "5 million users.") == .accepted)
        #expect(verdict("the twenty first of may", "The 21st of May.") == .accepted)
        #expect(verdict("call me at five five five one two three four", "Call me at 555-1234.") == .accepted)
    }

    @Test func digitsBecomingWordsAreNotInvented() {
        #expect(verdict("i have 3 cats", "I have three cats.") == .accepted)
    }

    // MARK: - Number canonicalisation

    @Test func canonicalNumbers() {
        func canonical(_ text: String) -> [String] { NumberWords.canonical(text.split(separator: " ").map(String.init)) }
        #expect(canonical("twenty five") == ["25"])
        #expect(canonical("a hundred") == ["a", "100"])
        #expect(canonical("nineteen hundred") == ["1900"])
        #expect(canonical("three thirty") == ["3", "30"])
        #expect(canonical("one hundred and twenty third") == ["123rd"])
        #expect(canonical("second place") == ["2nd", "place"])
        #expect(canonical("rock and roll") == ["rock", "and", "roll"])
        #expect(canonical("zero one") == ["0", "1"])
        #expect(canonical("5 apples") == ["5", "apples"])
    }
}
