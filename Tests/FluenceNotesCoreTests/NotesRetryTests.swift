import Foundation
import Testing

@testable import FluenceNotesCore

struct NotesCallRetryTests {
    @Test func eachTryGetsALongerLimit() {
        let limits = (1...NotesRetry.callAttempts).map { NotesRetry.callTimeout(attempt: $0, base: 90) }
        #expect(limits == [90, 135, 180])
        #expect(NotesRetry.callTimeout(attempt: 0, base: 90) == 90)
    }

    @Test func aBusyModelBacksOff() {
        #expect(NotesRetry.delay(beforeAttempt: 2, after: .busy) == 10)
        #expect(NotesRetry.delay(beforeAttempt: 3, after: .busy) == 30)
    }

    @Test func aTimeoutIsRetriedSoon() {
        #expect(NotesRetry.delay(beforeAttempt: 2, after: .timedOut) == 2)
        #expect(NotesRetry.delay(beforeAttempt: 3, after: .timedOut) == 2)
    }

    @Test func noMoreThanTheAttempts() {
        #expect(NotesRetry.delay(beforeAttempt: NotesRetry.callAttempts + 1, after: .busy) == nil)
        #expect(NotesRetry.delay(beforeAttempt: 1, after: .busy) == nil)
    }

    @Test func otherFailuresAreNotRetriedByTheCall() {
        for outcome in NotesOutcome.allCases where outcome != .busy && outcome != .timedOut {
            #expect(NotesRetry.delay(beforeAttempt: 2, after: outcome) == nil)
        }
    }
}

struct NotesLaunchResumeTests {
    @Test func notesAlreadyThereForgetTheJob() {
        #expect(NotesRetry.atLaunch(NotesJob(resumes: 0, lastOutcome: .timedOut), hasNotes: true) == .forget)
    }

    @Test func anInterruptedRunIsResumedTwice() {
        #expect(NotesRetry.atLaunch(NotesJob(resumes: 0), hasNotes: false) == .resume(counts: true))
        #expect(NotesRetry.atLaunch(NotesJob(resumes: 1), hasNotes: false) == .resume(counts: true))
        #expect(NotesRetry.atLaunch(NotesJob(resumes: 2), hasNotes: false) == .showFailure(.failed))
    }

    @Test func timeoutsAndABusyModelAreResumedTwice() {
        for outcome in [NotesOutcome.timedOut, .busy] {
            #expect(NotesRetry.atLaunch(NotesJob(resumes: 1, lastOutcome: outcome), hasNotes: false) == .resume(counts: true))
            #expect(NotesRetry.atLaunch(NotesJob(resumes: 2, lastOutcome: outcome), hasNotes: false) == .showFailure(outcome))
        }
    }

    @Test func waitingForAppleIntelligenceUsesNoTries() {
        #expect(NotesRetry.atLaunch(NotesJob(resumes: 9, lastOutcome: .unavailable), hasNotes: false) == .resume(counts: false))
        #expect(NotesRetry.willResume(after: .unavailable, resumes: 9))
    }

    @Test func lastingFailuresAreShownNotRetried() {
        for outcome in [NotesOutcome.tooShort, .declined, .unsupportedLanguage, .empty, .failed] {
            #expect(!outcome.isTransient)
            #expect(NotesRetry.atLaunch(NotesJob(lastOutcome: outcome), hasNotes: false) == .showFailure(outcome))
            #expect(!NotesRetry.willResume(after: outcome, resumes: 0))
        }
    }

    @Test func theMessageSaysARetryOnlyWhenOneComes() {
        #expect(NotesRetry.willResume(after: .timedOut, resumes: 0))
        #expect(NotesRetry.willResume(after: .busy, resumes: 1))
        #expect(!NotesRetry.willResume(after: .timedOut, resumes: NotesRetry.launchResumes))
    }

    @Test func aJobRoundTrips() throws {
        let job = NotesJob(resumes: 1, lastOutcome: .busy)
        let back = try JSONDecoder().decode(NotesJob.self, from: JSONEncoder().encode(job))
        #expect(back == job)
    }
}
