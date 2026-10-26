import Foundation
import Testing

@testable import FluenceCore

/// FLU-37: the onboarding's « Essayer » step.
struct TryDictationTests {
    private func phase(
        granted: Bool = true,
        dictating: Bool = false,
        ending: TryDictation.Ending? = nil,
        text: Bool = false
    ) -> TryDictation.Phase {
        TryDictation.phase(requiredGranted: granted, isDictating: dictating, lastEnding: ending, fieldHasText: text)
    }

    @Test func waitsUntilTheFirstDictation() {
        #expect(phase() == .waiting)
        // Typing by hand is not a dictation.
        #expect(phase(text: true) == .waiting)
    }

    @Test func showsTheDictationWhileItRuns() {
        #expect(phase(dictating: true) == .dictating)
        #expect(phase(dictating: true, ending: .typed, text: true) == .dictating)
        #expect(phase(granted: false, dictating: true) == .dictating)
    }

    @Test func succeedsOnlyWhenTheTextLandedInTheField() {
        #expect(phase(ending: .typed, text: true) == .success)
        #expect(TryDictation.isDone(.success))
        // Typed, then emptied by the user: back to waiting.
        #expect(phase(ending: .typed, text: false) == .waiting)
        // Left on the clipboard, or an error: the capsule explains, the step waits.
        #expect(phase(ending: .other, text: true) == .waiting)
    }

    @Test func nothingHeardOffersAnotherMicrophone() {
        #expect(phase(ending: .nothingHeard) == .nothingHeard)
        #expect(phase(ending: .nothingHeard, text: true) == .nothingHeard)
        #expect(!TryDictation.isDone(.nothingHeard))
    }

    @Test func withoutTheGrantsItIsBlocked() {
        #expect(phase(granted: false) == .blocked)
        #expect(phase(granted: false, ending: .typed, text: true) == .blocked)
        #expect(!TryDictation.isDone(.blocked))
    }
}
