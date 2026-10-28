import Foundation
import Testing

@testable import FluenceMeetingCore

/// FLU-33: when the call window's participant list counts, and how a walk of it is bounded.
struct ParticipantRosterTests {
    @Test("names from every read are kept, de-duplicated, in the order first seen")
    func namesAccumulate() {
        var roster = ParticipantRoster()
        roster.record(ParticipantRead(names: ["Ada", "Bob"], complete: false))
        roster.record(ParticipantRead(names: ["bob", "Cy"], complete: true))
        #expect(roster.names == ["Ada", "Bob", "Cy"])
        #expect(roster.reads == 2)
        #expect(roster.trustedCount == nil)
    }

    @Test("an empty roster is not complete")
    func emptyRoster() {
        #expect(!ParticipantRoster().isComplete)
        #expect(ParticipantRoster().trustedCount == nil)
    }

    @Test("a list label is recognised alone or with its count")
    func listLabels() {
        #expect(ParticipantNames.isListLabel("Participants"))
        #expect(ParticipantNames.isListLabel("Participants (4)"))
        #expect(ParticipantNames.isListLabel("In this meeting (12)"))
        #expect(ParticipantNames.isListLabel("People · 3"))
        #expect(ParticipantNames.isListLabel("Dans la réunion"))
        #expect(!ParticipantNames.isListLabel("Participants list settings"))
        #expect(!ParticipantNames.isListLabel("Chat"))
    }

    @Test("the count the app prints beside the label")
    func reportedCount() {
        #expect(ParticipantNames.reportedCount(inLabel: "Participants (4)") == 4)
        #expect(ParticipantNames.reportedCount(inLabel: "In this meeting ( 12 )") == 12)
        #expect(ParticipantNames.reportedCount(inLabel: "People · 3") == 3)
        #expect(ParticipantNames.reportedCount(inLabel: "Participants à la réunion (2)") == 2)
        #expect(ParticipantNames.reportedCount(inLabel: "Participants") == nil)
        #expect(ParticipantNames.reportedCount(inLabel: "Participants (beaucoup)") == nil)
        #expect(ParticipantNames.reportedCount(inLabel: "Participants (4") == nil)
    }
}

struct WalkBudgetTests {
    /// A clock the test moves by hand.
    final class FakeClock: @unchecked Sendable {
        var now: TimeInterval = 100
    }

    @Test("the element cap ends the walk")
    func elementCap() {
        let clock = FakeClock()
        var budget = WalkBudget(maxElements: 3, maxDuration: 10, clock: { clock.now })
        var spent: Bool
        spent = budget.spend(); #expect(spent)
        spent = budget.spend(); #expect(spent)
        spent = budget.spend(); #expect(spent)
        #expect(!budget.isExhausted)
        spent = budget.spend(); #expect(!spent)
        #expect(budget.isExhausted)
        #expect(budget.visited == 3)
    }

    @Test("the time budget ends the walk, and stays spent")
    func timeBudget() {
        // Binary fractions, so the clock arithmetic is exact.
        let clock = FakeClock()
        var budget = WalkBudget(maxElements: 1_000, maxDuration: 0.25, clock: { clock.now })
        var spent: Bool
        spent = budget.spend(); #expect(spent)
        clock.now += 0.125
        spent = budget.spend(); #expect(spent)
        #expect(budget.remaining == 0.125)
        clock.now += 0.125
        spent = budget.spend(); #expect(!spent)
        #expect(budget.isExhausted)
        #expect(budget.remaining == 0)
        clock.now -= 1   // a clock going back does not revive a spent budget
        spent = budget.spend(); #expect(!spent)
    }

    @Test("the participant walk's defaults")
    func defaults() {
        let budget = WalkBudget()
        #expect(budget.maxElements == 4_000)
        #expect(budget.maxDuration == 0.15)
    }
}
