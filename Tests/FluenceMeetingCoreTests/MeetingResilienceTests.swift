import Foundation
import Testing

@testable import FluenceMeetingCore

struct SystemEventStopTests {
    @Test func aLockedOrDarkScreenKeepsRecording() {
        #expect(StopPolicy.reason(for: .screenLocked) == nil)
        #expect(StopPolicy.reason(for: .displaySlept) == nil)
    }

    @Test func realSleepAndAnotherUserStopAndSave() {
        #expect(StopPolicy.reason(for: .systemWillSleep) == .systemSleep)
        #expect(StopPolicy.reason(for: .userSwitchedOut) == .userSwitched)
    }

    @Test func onlyTheUsersOwnStopSilencesTheOffer() {
        #expect(!StopPolicy.offersAgain(after: .user))
        for reason in [StopReason.callEnded, .silence, .maxDuration, .systemSleep, .userSwitched, .captureFailed] {
            #expect(StopPolicy.offersAgain(after: reason))
        }
    }

    @Test func anOldScreenLockedValueStillDecodes() throws {
        let decoded = try JSONDecoder().decode(StopReason.self, from: Data(#""screenLocked""#.utf8))
        #expect(decoded == .screenLocked)
    }
}

struct RecoveryPlanTests {
    @Test func twoAttemptsThenOneAnnouncementThenQuiet() {
        #expect(RecoveryPlan.decide(previousAttempts: 0) == .attempt(number: 1))
        #expect(RecoveryPlan.decide(previousAttempts: 1) == .attempt(number: 2))
        #expect(RecoveryPlan.decide(previousAttempts: 2) == .giveUp(announce: true))
        #expect(RecoveryPlan.decide(previousAttempts: RecoveryPlan.announcedCount) == .giveUp(announce: false))
    }

    @Test func aCorruptCountIsReadAsNone() {
        #expect(RecoveryPlan.decide(previousAttempts: -3) == .attempt(number: 1))
    }
}

struct TapWatchdogTests {
    @Test func waitsDoubleAndStayAtAMinute() {
        let waits = (1...8).map { TapWatchdog.delay(afterRebuilds: $0) }
        #expect(waits == [5, 10, 20, 40, 60, 60, 60, 60])
        #expect(TapWatchdog.delay(afterRebuilds: 10_000) == 60)
    }

    @Test func firstRebuildAfterFiveSecondsOfSilence() {
        #expect(!TapWatchdog.isRebuildDue(silentFor: 4.9, sinceLastRebuild: nil, rebuilds: 0))
        #expect(TapWatchdog.isRebuildDue(silentFor: 5, sinceLastRebuild: nil, rebuilds: 0))
    }

    @Test func laterRebuildsFollowTheBackoffWithNoCap() {
        #expect(!TapWatchdog.isRebuildDue(silentFor: 30, sinceLastRebuild: 9, rebuilds: 2))
        #expect(TapWatchdog.isRebuildDue(silentFor: 30, sinceLastRebuild: 10, rebuilds: 2))
        #expect(TapWatchdog.isRebuildDue(silentFor: 3_600, sinceLastRebuild: 60, rebuilds: 200))
    }

    @Test func noticesAreFrenchAndHonest() {
        #expect(TapWatchdog.notice(nextTryIn: 20).contains("20\u{00A0}s"))
        #expect(DroppedAudio.notice(blocks: 0) == nil)
        #expect(DroppedAudio.notice(blocks: 3) != nil)
    }
}
