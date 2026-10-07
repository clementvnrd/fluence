import Foundation
import Testing

@testable import FluenceCore

/// Behaviour carried over from Clement's build (FLU-11).
struct SpeechRepairsTests {
    @Test func scratchThatKeepsWhatFollows() {
        #expect(SpeechRepairs.backtrack("send it to Paul scratch that send it to Marie") == "send it to Marie")
        #expect(SpeechRepairs.backtrack("bonjour efface tout, salut") == "salut")
    }

    @Test func selfCorrectionKeepsTheRevisedWord() {
        #expect(SpeechRepairs.backtrack("rendez-vous mardi, en fait mercredi") == "rendez-vous mercredi")
        #expect(SpeechRepairs.backtrack("meet on Tuesday, actually Wednesday") == "meet on Wednesday")
    }

    @Test func repeatedWordsCollapse() {
        #expect(SpeechRepairs.deduplicateConsecutiveWords(in: "c'est c'est bien") == "c'est bien")
        #expect(SpeechRepairs.deduplicateConsecutiveWords(in: "il y a il y a un problème") == "il y a un problème")
        #expect(SpeechRepairs.deduplicateConsecutiveWords(in: "the the end") == "the end")
    }

    @Test func emphasisAndReflexivesStay() {
        #expect(SpeechRepairs.deduplicateConsecutiveWords(in: "très très bien") == "très très bien")
        #expect(SpeechRepairs.deduplicateConsecutiveWords(in: "nous nous sommes vus") == "nous nous sommes vus")
        #expect(SpeechRepairs.deduplicateConsecutiveWords(in: "vous vous trompez") == "vous vous trompez")
    }

    @Test func stutteredPrefixesGo() {
        #expect(SpeechRepairs.removeStutterPrefixes(in: "un pro problème") == "un problème")
        #expect(SpeechRepairs.removeStutterPrefixes(in: "je ne suis pas passé") == "je ne suis pas passé")
    }

    @Test func spokenListsBecomeLines() {
        let text = SpeechRepairs.after(
            "Les courses. Premièrement du pain, deuxièmement du lait.",
            language: .french,
            developer: false
        )
        // As in Clement's build, the punctuation before a list cue gives way to the line break.
        #expect(text == "Les courses\n1. Du pain\n2. Du lait.")
    }

    @Test func developerFormatting() {
        #expect(SpeechRepairs.developerSymbols("git commit double tiret amend") == "git commit --amend")
        #expect(SpeechRepairs.developerSymbols("if a égal égal b accolade ouvrante") == "if a == b {")
        #expect(SpeechRepairs.after("Brew install ripgrep.", language: .english, developer: true) == "Brew install ripgrep")
        #expect(SpeechRepairs.after("One. Two.", language: .english, developer: true) == "One. Two.")
    }

    @Test func otherLanguagesAreLeftAlone() {
        #expect(SpeechRepairs.before("das das Haus", language: .german) == "das das Haus")
    }

    @Test func developerToolsAreRecognisedByBundleID() {
        #expect(DeveloperTools.contains(bundleID: "com.apple.Terminal"))
        #expect(DeveloperTools.contains(bundleID: "com.microsoft.VSCode"))
        #expect(!DeveloperTools.contains(bundleID: "com.apple.mail"))
        #expect(!DeveloperTools.contains(bundleID: nil))
    }
}

struct TapToLockGestureTests {
    private typealias G = PushToTalkGesture

    @Test func aShortTapLocksTheRecordingOn() {
        var gesture = G(tapLocks: true)
        #expect(gesture.keyDown(at: 0) == [.start(command: false)])
        #expect(gesture.keyUp(at: 0.2) == [.enterHandsFree])
        #expect(gesture.phase == .handsFree(keyDown: false))
        // The next press ends it, on the press.
        #expect(gesture.keyDown(at: 5) == [.finish])
        #expect(gesture.keyUp(at: 5.1) == [])
        #expect(gesture.phase == .idle)
    }

    @Test func aHoldStillFinishesOnRelease() {
        var gesture = G(tapLocks: true)
        _ = gesture.keyDown(at: 0)
        #expect(gesture.keyUp(at: 0.5) == [.finish])
        #expect(gesture.tapDeadline == nil)
    }

    @Test func clementsThresholdIsLongerThanTheDoubleTapOne() {
        var gesture = G(tapLocks: true)
        _ = gesture.keyDown(at: 0)
        // 0.32 s: a hold for the double-tap machine, a tap for Clement's.
        #expect(gesture.keyUp(at: 0.32) == [.enterHandsFree])
    }

    @Test func theCommandShortcutStartsACommand() {
        var gesture = G(tapLocks: true)
        #expect(gesture.keyDown(at: 0, commandModifier: true) == [.start(command: true)])
        #expect(gesture.keyUp(at: 1) == [.finish])
    }
}

struct SnippetCommandWordTests {
    private let calendly = Snippet(trigger: "mon calendly", expansion: "https://example.com/meet")

    @Test func aLeadingCommandWordStillExpands() {
        #expect(SnippetMatcher.wholeUtterance("Insère mon calendly.", snippets: [calendly]) == calendly)
        #expect(SnippetMatcher.wholeUtterance("paste mon calendly", snippets: [calendly]) == calendly)
    }

    @Test func otherLeadingWordsDoNot() {
        #expect(SnippetMatcher.wholeUtterance("voici mon calendly", snippets: [calendly]) == nil)
    }
}
