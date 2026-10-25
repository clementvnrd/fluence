import Foundation
import Testing

@testable import FluenceMeetingCore

struct QuitPlanTests {
    @Test func nothingRecordingQuitsAtOnce() {
        #expect(QuitPlan.decide(recording: false, origin: .user) == .quitNow)
        #expect(QuitPlan.decide(recording: false, origin: .system) == .quitNow)
    }

    @Test func theUserIsAskedBeforeARecordingStops() {
        #expect(QuitPlan.decide(recording: true, origin: .user) == .ask)
    }

    @Test func aLogOutOrShutDownStopsAndSavesWithoutAsking() {
        #expect(QuitPlan.decide(recording: true, origin: .system) == .stopAndSave)
    }

    @Test func onlyAQuitReasonMeansTheSystem() {
        #expect(QuitPlan.origin(quitReason: nil) == .user)
        #expect(QuitPlan.origin(quitReason: 0) == .user)
        for code in ["logo", "rlgo", "rrst", "rest", "rsdn", "shut"] {
            #expect(QuitPlan.origin(quitReason: QuitPlan.fourCharCode(code)) == .system)
        }
    }

    @Test func theQuitReasonKeywordIsWhy() {
        // 'why?' = 0x7768793F, as in AERegistry.h (kAEQuitReason).
        #expect(QuitPlan.quitReasonKeyword == 0x7768_793F)
    }

    @Test func aLogOutWaitsLessThanTheUser() {
        #expect(QuitPlan.maximumWait(for: .system) < QuitPlan.maximumWait(for: .user))
        #expect(QuitPlan.maximumWait(for: .system) > 0)
    }

    @Test func theQuestionIsInFrench() {
        #expect(QuitPlan.question == "Arrêter et enregistrer la réunion ?")
        #expect(QuitPlan.confirmTitle == "Arrêter et quitter")
        #expect(QuitPlan.cancelTitle == "Annuler")
    }

    @Test func aQuitStopIsAnAutomaticStop() {
        // Fluence is going away; the stop is not the user's « Arrêter » on the call.
        #expect(StopPolicy.offersAgain(after: .appQuit))
        let decoded = try? JSONDecoder().decode(StopReason.self, from: Data(#""appQuit""#.utf8))
        #expect(decoded == .appQuit)
    }
}

struct TranscriptionRetryTests {
    private func span(_ source: AudioSource, _ start: TimeInterval, _ end: TimeInterval) -> UntranscribedSpan {
        UntranscribedSpan(source: source, start: start, end: end)
    }

    @Test func retriesInTimeOrderWithoutRepeatsOrEmptySpans() {
        let spans = [
            span(.system, 30, 40),
            span(.microphone, 5, 9),
            span(.system, 30, 40),
            span(.microphone, 12, 12),
            span(.microphone, 20, 18),
            span(.system, .nan, 3),
            span(.microphone, 30, 35),
        ]
        #expect(TranscriptionRetry.plan(spans) == [
            span(.microphone, 5, 9),
            span(.microphone, 30, 35),
            span(.system, 30, 40),
        ])
    }

    @Test func spansAreNotMergedEvenWhenTheyTouch() {
        let spans = [span(.system, 0, 14.5), span(.system, 14.5, 29)]
        #expect(TranscriptionRetry.plan(spans).count == 2)
    }

    @Test func nothingLeftIsNil() {
        #expect(TranscriptionRetry.remaining([]) == nil)
        #expect(TranscriptionRetry.remaining([span(.system, 1, 2)])?.count == 1)
    }

    @Test func aMeetingSavedBeforeFLU54StillDecodes() throws {
        let old = #"{"id":"6F1C1B0A-6C1A-4E7C-9B57-0D6B3E5E2A11","title":"T","trigger":"manual","startedAt":"2026-10-01T10:00:00Z","attendees":[],"speakers":[{"id":"me"}],"segments":[],"userNotes":"","keepAudio":false}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(old.utf8))
        #expect(meeting.untranscribed == nil)
    }

    @Test func untranscribedSpansSurviveASave() throws {
        var meeting = Meeting(title: "T", startedAt: Date(timeIntervalSince1970: 0))
        meeting.untranscribed = [span(.system, 1, 4)]
        let data = try JSONEncoder().encode(meeting)
        let back = try JSONDecoder().decode(Meeting.self, from: data)
        #expect(back.untranscribed == [span(.system, 1, 4)])
    }
}

struct MeetingCompletionTests {
    @Test func aFailedSaveKeepsEverything() {
        let plan = MeetingCompletion.plan(saved: false, untranscribed: 0, keepAudio: false)
        #expect(plan == .init(deleteAudio: false, clearMarker: false, announceFinalized: false))
    }

    @Test func missingSentencesKeepTheAudioAndTheMarkerAndHoldTheNotes() {
        for keepAudio in [false, true] {
            let plan = MeetingCompletion.plan(saved: true, untranscribed: 2, keepAudio: keepAudio)
            #expect(plan == .init(deleteAudio: false, clearMarker: false, announceFinalized: false))
        }
    }

    @Test func aCompleteMeetingDropsItsAudioUnlessKept() {
        #expect(MeetingCompletion.plan(saved: true, untranscribed: 0, keepAudio: false)
            == .init(deleteAudio: true, clearMarker: true, announceFinalized: true))
        #expect(MeetingCompletion.plan(saved: true, untranscribed: 0, keepAudio: true)
            == .init(deleteAudio: false, clearMarker: true, announceFinalized: true))
    }

    @Test func givingUpOnMissingSentencesStillWritesNotes() {
        #expect(MeetingCompletion.announcesOnGivingUp(untranscribed: 3))
        #expect(!MeetingCompletion.announcesOnGivingUp(untranscribed: 0))
    }
}
