import Testing

@testable import FluenceMeetingCore

/// The detection card records only after a click, unless the user chose a delay (FLU-34).
struct DetectionOfferTests {
    @Test("by default, a card left alone for a whole call records nothing")
    func ignoredCardNeverRecords() {
        var offer = DetectionOffer(autoRecordSeconds: DetectionOffer.autoRecordChoices[0])
        #expect(offer.remaining == nil)
        #expect(offer.total == nil)
        // A three-hour call, one tick a second.
        let steps = (0..<(3 * 3600)).map { _ in offer.tick(callOngoing: true) }
        #expect(steps.allSatisfy { $0 == .wait })
        #expect(offer.remaining == nil)
    }

    @Test("the default delay is the first choice: none")
    func defaultIsNever() {
        #expect(DetectionOffer.autoRecordChoices.first == 0)
    }

    @Test("a delay chosen in Settings counts down, then records once")
    func chosenDelayRecords() {
        var offer = DetectionOffer(autoRecordSeconds: 3)
        #expect(offer.total == 3)
        #expect(offer.remaining == 3)
        #expect(offer.tick(callOngoing: true) == .wait)
        #expect(offer.remaining == 2)
        #expect(offer.tick(callOngoing: true) == .wait)
        #expect(offer.remaining == 1)
        #expect(offer.tick(callOngoing: true) == .record)
        #expect(offer.remaining == 0)
    }

    @Test("the call ending takes the card down, with or without a delay")
    func callEndedWithdraws() {
        var waiting = DetectionOffer(autoRecordSeconds: 0)
        #expect(waiting.tick(callOngoing: false) == .withdraw)

        var counting = DetectionOffer(autoRecordSeconds: 10)
        #expect(counting.tick(callOngoing: true) == .wait)
        #expect(counting.tick(callOngoing: false) == .withdraw)
        #expect(counting.remaining == 9)
    }

    @Test("a negative stored delay waits for a click")
    func negativeDelayWaits() {
        var offer = DetectionOffer(autoRecordSeconds: -5)
        #expect(offer.remaining == nil)
        #expect(offer.tick(callOngoing: true) == .wait)
    }
}
