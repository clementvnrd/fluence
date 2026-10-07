import Testing

@testable import FluenceCore

struct PushToTalkGestureTests {
    private typealias G = PushToTalkGesture

    // MARK: - Hold to talk

    @Test func holdStartsAndReleaseFinishes() {
        var gesture = G()
        #expect(gesture.keyDown(at: 0) == [.start(command: false)])
        #expect(gesture.keyUp(at: 2) == [.finish])
        #expect(gesture.phase == .idle)
    }

    @Test func shortTapKeepsRecordingUntilTheWindowCloses() {
        var gesture = G()
        _ = gesture.keyDown(at: 0)
        #expect(gesture.keyUp(at: 0.1) == [])
        #expect(gesture.tapDeadline == 0.1 + G.doubleTapWindow)
        #expect(gesture.windowElapsed(tappedAt: 0.1) == [.finish])
        #expect(gesture.phase == .idle)
    }

    @Test func staleWindowTimerDoesNothing() {
        var gesture = G()
        _ = gesture.keyDown(at: 0)
        _ = gesture.keyUp(at: 0.1)
        _ = gesture.keyDown(at: 0.2)    // hands-free now
        #expect(gesture.windowElapsed(tappedAt: 0.1) == [])
        #expect(gesture.phase == .handsFree(keyDown: true))
    }

    // MARK: - Hands-free

    @Test func doubleTapEntersHandsFreeAndATapEndsIt() {
        var gesture = G()
        #expect(gesture.keyDown(at: 0) == [.start(command: false)])
        #expect(gesture.keyUp(at: 0.12) == [])
        #expect(gesture.keyDown(at: 0.3) == [.enterHandsFree])
        #expect(gesture.keyUp(at: 0.4) == [])
        #expect(gesture.phase == .handsFree(keyDown: false))
        // Long after: the release of the second tap did not end it.
        #expect(gesture.keyDown(at: 30) == [.finish])
        #expect(gesture.keyUp(at: 30.1) == [])
        #expect(gesture.phase == .idle)
    }

    @Test func secondTapAfterTheWindowIsNotADoubleTap() {
        var gesture = G()
        _ = gesture.keyDown(at: 0)
        _ = gesture.keyUp(at: 0.1)
        // The timer was late; the press finishes the stray tap and starts nothing.
        #expect(gesture.keyDown(at: 0.1 + G.doubleTapWindow + 0.05) == [.finish])
        #expect(gesture.keyUp(at: 1) == [])
        #expect(gesture.phase == .idle)
    }

    @Test func spaceChordEntersHandsFreeAndIsSwallowed() {
        var gesture = G()
        _ = gesture.keyDown(at: 0)
        let chord = gesture.space()
        #expect(chord.consume)
        #expect(chord.actions == [.enterHandsFree])
        // Auto-repeat while still held: swallowed, nothing new.
        let repeated = gesture.space()
        #expect(repeated.consume && repeated.actions.isEmpty)
        // A long hold that became hands-free does not finish on release.
        #expect(gesture.keyUp(at: 5) == [])
        #expect(gesture.keyDown(at: 9) == [.finish])
    }

    @Test func spaceWithoutTheKeyHeldIsTyped() {
        var gesture = G()
        #expect(gesture.space().consume == false)
        _ = gesture.keyDown(at: 0)
        _ = gesture.keyUp(at: 0.1)      // tapped: key up
        #expect(gesture.space().consume == false)
    }

    // MARK: - Command Mode

    @Test func modifierAlreadyDownStartsACommand() {
        var gesture = G()
        #expect(gesture.keyDown(at: 0, commandModifier: true) == [.start(command: true)])
    }

    @Test func modifierDuringTheHoldMarksACommand() {
        var gesture = G()
        _ = gesture.keyDown(at: 0)
        #expect(gesture.commandModifierDown() == [.markCommand])
        #expect(gesture.keyUp(at: 3) == [.finish])
        #expect(gesture.commandModifierDown() == [])
    }

    // MARK: - Resynchronisation

    @Test func sessionEndingUnderTheKeyIgnoresItsRelease() {
        var gesture = G()
        _ = gesture.keyDown(at: 0)
        gesture.sessionEnded()          // e.g. Esc
        #expect(gesture.keyUp(at: 2) == [])
        #expect(gesture.phase == .idle)
        #expect(gesture.keyDown(at: 3) == [.start(command: false)])
    }

    @Test func handsFreeStoppedElsewhereResetsToIdle() {
        var gesture = G()
        _ = gesture.keyDown(at: 0)
        _ = gesture.space()
        _ = gesture.keyUp(at: 1)
        gesture.sessionEnded()          // the HUD's Stop key, or the recording limit
        #expect(gesture.keyDown(at: 5) == [.start(command: false)])
    }

    @Test func tapInterruptionKeepsHandsFreeWaitingForItsTap() {
        var gesture = G()
        _ = gesture.keyDown(at: 0)
        _ = gesture.space()
        gesture.tapInterrupted()
        #expect(gesture.keyDown(at: 4) == [.finish])
    }

    @Test func tapInterruptionForgetsAHold() {
        var gesture = G()
        _ = gesture.keyDown(at: 0)
        gesture.tapInterrupted()
        // The key-up was lost; the next press is a fresh start.
        #expect(gesture.keyUp(at: 1) == [])
        #expect(gesture.keyDown(at: 2) == [.start(command: false)])
    }

    @Test func repeatedKeyDownIsIgnored() {
        var gesture = G()
        _ = gesture.keyDown(at: 0)
        #expect(gesture.keyDown(at: 0.5) == [])
    }
}
