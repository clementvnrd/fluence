import Foundation
import Testing

@testable import FluenceCore

/// FLU-29: what the capsule says after a dictation, and for how long.
struct CapsuleMessageTests {
    /// Every message the capsule can show for a result.
    private static var everyMessage: [CapsuleMessage] {
        DictationFailure.allCases.map(CapsuleMessage.failure)
            + CapsuleMessage.NotTypedReason.allCases.flatMap { reason in
                [true, false].map { CapsuleMessage.notTyped(reason, canPasteLast: $0) }
            }
            + [.cancelled, .nothingHeard(microphone: "MacBook Pro"), .nothingHeard(microphone: nil)]
    }

    /// Words that only show up when an English message leaks through (an engine's own error
    /// text, a placeholder). Checked as whole words, lower-cased.
    private static let englishWords: Set<String> = [
        "the", "a", "an", "failed", "failure", "error", "not", "could", "couldn't", "operation",
        "engine", "microphone", "mic", "copied", "paste", "pasted", "settings", "retry", "nothing",
        "heard", "accessibility", "denied", "unavailable", "with", "timeout", "timed", "out",
        "transcription", "stopped", "loop", "changed", "app", "clipboard", "permission",
    ]

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
    }

    @Test func everyStringIsFrench() {
        // « app » is French usage here (« Vous avez changé d'app »), « transcription » too:
        // they are only English when they stand in an English sentence, which the other words
        // would catch.
        let allowed: Set<String> = ["d'app", "app", "transcription", "a"]
        for message in Self.everyMessage {
            let texts = [message.title, message.detail, message.action?.title].compactMap { $0 }
            for text in texts {
                let english = Self.words(text).filter { Self.englishWords.contains($0) && !allowed.contains($0) }
                #expect(english.isEmpty, "English in « \(text) »: \(english)")
                #expect(!text.isEmpty)
                #expect(!text.contains("  "))
            }
        }
    }

    @Test func everyFailureHasAFrenchTitleAndDetail() {
        for failure in DictationFailure.allCases {
            let message = CapsuleMessage.failure(failure)
            #expect(message.icon == .warning)
            #expect(message.detail != nil)
            // Short enough for one line of the 430-pt capsule at 13 pt (title) / 10 pt (detail):
            // both are cut at their end if a translation ever grows, never at their start.
            #expect(message.title.count <= 30, "\(message.title)")
            #expect((message.detail ?? "").count <= 44, "\(message.detail ?? "")")
            // Accented French shows the strings are not ASCII placeholders.
            #expect(message.title.first?.isUppercase == true)
        }
    }

    @Test func approvedStringsAreExact() {
        #expect(CapsuleMessage.failure(.engineFailed(.parakeet, canRetry: true))
            == CapsuleMessage(icon: .warning, title: "La transcription a échoué", detail: "Parakeet n'a pas répondu", action: .retry))
        #expect(CapsuleMessage.failure(.microphoneDenied)
            == CapsuleMessage(icon: .warning, title: "Micro indisponible", detail: "Accès refusé dans Réglages Système", action: .microphoneSettings))
        // FLU-120: nothing on the clipboard; ⌃⌘V when it can work, else the history.
        #expect(CapsuleMessage.notTyped(.appChanged, canPasteLast: true)
            == CapsuleMessage(icon: .notTyped, title: "Non collé — collez avec ⌃⌘V", detail: "Vous avez changé d'app"))
        #expect(CapsuleMessage.notTyped(.appChanged, canPasteLast: false)
            == CapsuleMessage(icon: .notTyped, title: "Non collé — voir Transcriptions", detail: "Vous avez changé d'app"))
        // ⌃⌘V needs the grant too: never offered without it.
        for canPasteLast in [true, false] {
            #expect(CapsuleMessage.notTyped(.noAccessibility, canPasteLast: canPasteLast)
                == CapsuleMessage(icon: .notTyped, title: "Non collé — voir Transcriptions", detail: "Accessibilité non autorisée", action: .accessibilitySettings))
        }
        #expect(CapsuleMessage.nothingHeard(microphone: "MacBook Pro")
            == CapsuleMessage(icon: .nothingHeard, title: "Rien entendu", detail: "Micro\u{00A0}: MacBook Pro"))
    }

    @Test func theEngineIsNamedInTheDetail() {
        for engine in ComparedEngine.allCases {
            #expect(DictationFailure.engineFailed(engine, canRetry: true).detail.hasPrefix(engine.displayName))
            #expect(DictationFailure.engineDidNotStart(engine, canRetry: false).detail.hasPrefix(engine.displayName))
            #expect(DictationFailure.stoppedEarly(engine).detail.hasPrefix(engine.displayName))
        }
    }

    @Test func oneActionAtMostAndRetryOnlyWhenARecordingIsKept() {
        for engine in ComparedEngine.allCases {
            #expect(DictationFailure.engineFailed(engine, canRetry: true).action == .retry)
            #expect(DictationFailure.engineFailed(engine, canRetry: false).action == nil)
            #expect(DictationFailure.repeated(engine, canRetry: true).action == .retry)
            #expect(DictationFailure.engineDidNotStart(engine, canRetry: true).action == .retry)
        }
        #expect(DictationFailure.microphoneDenied.action == .microphoneSettings)
        #expect(DictationFailure.microphoneDidNotStart.action == .soundSettings)
        #expect(DictationFailure.recordingExpired.action == nil)
    }

    @Test func buttonsAreBlueExceptTheHelpBesideACopy() {
        #expect(CapsuleMessage.Action.retry.isPrimary)
        #expect(CapsuleMessage.Action.microphoneSettings.isPrimary)
        #expect(CapsuleMessage.Action.soundSettings.isPrimary)
        #expect(!CapsuleMessage.Action.accessibilitySettings.isPrimary)
        #expect(CapsuleMessage.Action.retry.title == "Réessayer")
        #expect(CapsuleMessage.Action.accessibilitySettings.title == "Réglages")
    }

    @Test func aMessageWithAButtonStaysSixSeconds() {
        for message in Self.everyMessage {
            #expect(message.duration == (message.action == nil ? 3 : 6))
        }
    }

    @Test func theMicrophoneNameIsOptional() {
        #expect(CapsuleMessage.nothingHeard(microphone: nil).detail == nil)
        #expect(CapsuleMessage.nothingHeard(microphone: "  ").detail == nil)
    }

    @Test func thePasteLastShortcutGoesThroughShortcutLabel() {
        #expect(PasteLastShortcut.label == ShortcutLabel.display("⌃⌘V"))
        #expect(CapsuleMessage.notTyped(.appChanged, canPasteLast: true).title.hasSuffix(PasteLastShortcut.label))
    }

    @Test func failureKindsAreFixedWordsWithoutAccents() {
        for failure in DictationFailure.allCases {
            #expect(failure.kind.allSatisfy { $0.isASCII && $0.isLetter })
        }
    }
}

/// FLU-29: the capsule's timing as a state machine.
struct CapsuleTimelineTests {
    private let error = CapsuleMessage.failure(.engineFailed(.parakeet, canRetry: true))
    private let notice = CapsuleMessage.notice("Dernière transcription copiée.")

    @Test func aPlainMessageGoesAfterThreeSeconds() {
        var timeline = CapsuleTimeline()
        timeline.handle(.show(notice), at: 100)
        let id = timeline.messageID!
        #expect(timeline.deadline == 103)
        timeline.handle(.timerFired(id: id), at: 102.9)
        #expect(timeline.message == notice)
        timeline.handle(.timerFired(id: id), at: 103)
        #expect(timeline.phase == .hidden)
    }

    @Test func anErrorWithAnActionStaysSixSeconds() {
        var timeline = CapsuleTimeline()
        timeline.handle(.show(error), at: 0)
        #expect(timeline.deadline == 6)
        timeline.handle(.timerFired(id: timeline.messageID!), at: 3)
        #expect(timeline.message == error)
    }

    @Test func theSameMessageTwiceIsTwoMessages() {
        var timeline = CapsuleTimeline()
        timeline.handle(.show(notice), at: 0)
        let first = timeline.messageID!
        timeline.handle(.show(notice), at: 2)
        let second = timeline.messageID!
        #expect(first != second)
        // The first one's timer fires at 3 s: it must not take the second one down.
        timeline.handle(.timerFired(id: first), at: 3)
        #expect(timeline.messageID == second)
        timeline.handle(.timerFired(id: second), at: 5)
        #expect(timeline.phase == .hidden)
    }

    @Test func hoveringPausesTheClock() {
        var timeline = CapsuleTimeline()
        timeline.handle(.show(error), at: 0)
        let id = timeline.messageID!
        timeline.handle(.hover(true), at: 4)
        #expect(timeline.deadline == nil)
        timeline.handle(.timerFired(id: id), at: 60)
        #expect(timeline.message == error)
        // 2 s were left when the pointer came in.
        timeline.handle(.hover(false), at: 60)
        #expect(timeline.deadline == 62)
        timeline.handle(.timerFired(id: id), at: 62)
        #expect(timeline.phase == .hidden)
    }

    @Test func leavingAfterTheTimeRanOutLeavesAMoment() {
        var timeline = CapsuleTimeline()
        timeline.handle(.show(notice), at: 0)
        timeline.handle(.hover(true), at: 2.95)
        timeline.handle(.hover(false), at: 10)
        #expect(timeline.deadline == 10 + CapsuleTimeline.graceAfterHover)
    }

    @Test func aMessageShownUnderThePointerStartsPaused() {
        var timeline = CapsuleTimeline()
        timeline.handle(.hover(true), at: 0)
        timeline.handle(.show(error), at: 1)
        #expect(timeline.deadline == nil)
        timeline.handle(.hover(false), at: 5)
        #expect(timeline.deadline == 11)
    }

    @Test func theButtonClosesOnlyItsOwnMessage() {
        var timeline = CapsuleTimeline()
        timeline.handle(.show(error), at: 0)
        let first = timeline.messageID!
        timeline.handle(.show(error), at: 1)
        timeline.handle(.actionTaken(id: first), at: 1.5)
        #expect(timeline.message == error)
        timeline.handle(.actionTaken(id: timeline.messageID!), at: 2)
        #expect(timeline.phase == .hidden)
    }

    @Test func aNewDictationReplacesTheMessage() {
        var timeline = CapsuleTimeline()
        timeline.handle(.show(error), at: 0)
        let id = timeline.messageID!
        timeline.handle(.dictationStarted, at: 1)
        #expect(timeline.phase == .dictating)
        #expect(timeline.deadline == nil)
        // The old timer finds nothing of its own to close.
        timeline.handle(.timerFired(id: id), at: 6)
        #expect(timeline.phase == .dictating)
        timeline.handle(.dictationEnded, at: 7)
        #expect(timeline.phase == .hidden)
    }

    @Test func hoverWithNoMessageOnlyRemembersThePointer() {
        var timeline = CapsuleTimeline()
        timeline.handle(.hover(true), at: 0)
        #expect(timeline.isHovered)
        #expect(timeline.phase == .hidden)
        timeline.handle(.hover(true), at: 1)
        timeline.handle(.hover(false), at: 2)
        #expect(!timeline.isHovered)
    }
}

/// FLU-29: text goes only into the app focused at release.
struct InsertTargetPolicyTests {
    private let notes = InsertTargetPolicy.App(processID: 501, bundleID: "com.apple.Notes")
    private let mail = InsertTargetPolicy.App(processID: 777, bundleID: "com.apple.mail")

    @Test func sameAppInsert() {
        #expect(InsertTargetPolicy.decide(target: notes, frontmost: notes, hasAccessibility: true) == .insert)
    }

    @Test func anotherAppGetsNothingTyped() {
        #expect(InsertTargetPolicy.decide(target: notes, frontmost: mail, hasAccessibility: true) == .keep(.appChanged))
        #expect(InsertTargetPolicy.decide(target: notes, frontmost: nil, hasAccessibility: true) == .keep(.appChanged))
    }

    @Test func aRelaunchedAppIsAnotherApp() {
        let relaunched = InsertTargetPolicy.App(processID: 900, bundleID: notes.bundleID)
        #expect(InsertTargetPolicy.decide(target: notes, frontmost: relaunched, hasAccessibility: true) == .keep(.appChanged))
    }

    @Test func noGrantIsSaidFirst() {
        #expect(InsertTargetPolicy.decide(target: notes, frontmost: notes, hasAccessibility: false) == .keep(.noAccessibility))
        #expect(InsertTargetPolicy.decide(target: notes, frontmost: mail, hasAccessibility: false) == .keep(.noAccessibility))
    }

    @Test func unknownTargetKeepsTheOldBehaviour() {
        #expect(InsertTargetPolicy.decide(target: nil, frontmost: mail, hasAccessibility: true) == .insert)
    }
}

/// FLU-29: the kept recording and its retries.
struct DictationRetryTests {
    @Test func keptSixtySeconds() {
        #expect(DictationRetry.isAvailable(keptAt: 100, now: 100))
        #expect(DictationRetry.isAvailable(keptAt: 100, now: 159.9))
        #expect(!DictationRetry.isAvailable(keptAt: 100, now: 160))
        #expect(!DictationRetry.isAvailable(keptAt: 100, now: 99))
    }

    @Test func longRecordingsAreNotKept() {
        #expect(DictationRetry.shouldKeep(audioSeconds: 12))
        #expect(DictationRetry.shouldKeep(audioSeconds: 600))
        #expect(!DictationRetry.shouldKeep(audioSeconds: 601))
        #expect(!DictationRetry.shouldKeep(audioSeconds: 0))
        #expect(!DictationRetry.shouldKeep(audioSeconds: .nan))
    }

    @Test func oneAutomaticRetryOnTheSameEngine() {
        for engine in [ComparedEngine.apple, .parakeet, .whisper] {
            #expect(DictationRetry.automatic(after: .failed, engine: engine, attempts: 0, parakeetReady: true, whisperReady: true) == engine)
            #expect(DictationRetry.automatic(after: .failed, engine: engine, attempts: 1, parakeetReady: true, whisperReady: true) == nil)
        }
        #expect(DictationRetry.automatic(after: .repeated, engine: .apple, attempts: 0, parakeetReady: false, whisperReady: false) == .apple)
        #expect(DictationRetry.automatic(after: .repeated, engine: .parakeet, attempts: 0, parakeetReady: true, whisperReady: false) == .parakeet)
    }

    @Test func whisperLoopsAreAlreadyRetriedInside() {
        #expect(DictationRetry.automatic(after: .repeated, engine: .whisper, attempts: 0, parakeetReady: true, whisperReady: true) == nil)
    }

    @Test func anEngineThatDidNotStartHandsOver() {
        #expect(DictationRetry.automatic(after: .didNotStart, engine: .parakeet, attempts: 0, parakeetReady: true, whisperReady: false) == .apple)
        #expect(DictationRetry.automatic(after: .didNotStart, engine: .apple, attempts: 0, parakeetReady: true, whisperReady: false) == .parakeet)
        // Nothing else on disk: no automatic retry on the engine that just failed to start.
        #expect(DictationRetry.automatic(after: .didNotStart, engine: .apple, attempts: 0, parakeetReady: false, whisperReady: false) == nil)
    }

    @Test func retryGoesToAnotherEngineOnDisk() {
        #expect(DictationRetry.otherEngine(than: .parakeet, parakeetReady: true, whisperReady: true) == .apple)
        #expect(DictationRetry.otherEngine(than: .apple, parakeetReady: true, whisperReady: true) == .parakeet)
        #expect(DictationRetry.otherEngine(than: .apple, parakeetReady: false, whisperReady: true) == .whisper)
        #expect(DictationRetry.otherEngine(than: .apple, parakeetReady: false, whisperReady: false) == .apple)
        #expect(DictationRetry.otherEngine(than: .whisper, parakeetReady: true, whisperReady: true) == .parakeet)
        #expect(DictationRetry.otherEngine(than: .whisper, parakeetReady: false, whisperReady: true) == .apple)
    }
}
