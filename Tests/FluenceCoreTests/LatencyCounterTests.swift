import Foundation
import Testing

@testable import FluenceCore

/// FLU-31: the timings-only counter behind the latency budgets.
struct LatencyCounterTests {
    private func sample(speechEnd: Double?, audio: Double, keyUp: Double = 0.2) -> DictationLatency {
        DictationLatency(postRoll: 0.05, engine: 0.08, keyUpToText: keyUp, speechEndToText: speechEnd, audioSeconds: audio)
    }

    @Test func emptyHasNoMedian() {
        #expect(LatencyCounter().median(of: .speechEndToText) == nil)
    }

    @Test func medianIsTheMiddleValue() {
        var counter = LatencyCounter()
        for value in [0.30, 0.10, 0.20] { counter.record(sample(speechEnd: value, audio: 3)) }
        #expect(counter.median(of: .speechEndToText) == 0.20)
    }

    @Test func nearestRankOnAnEvenCount() {
        var counter = LatencyCounter()
        for value in [0.1, 0.2, 0.3, 0.4] { counter.record(sample(speechEnd: value, audio: 3)) }
        #expect(counter.median(of: .speechEndToText) == 0.2)
        #expect(counter.percentile(0.9, of: .speechEndToText) == 0.4)
        #expect(counter.percentile(0, of: .speechEndToText) == 0.1)
        #expect(counter.percentile(1, of: .speechEndToText) == 0.4)
    }

    @Test func shortAndLongDictationsAreSeparated() {
        var counter = LatencyCounter()
        counter.record(sample(speechEnd: 0.2, audio: 4))
        counter.record(sample(speechEnd: 0.22, audio: 10))
        counter.record(sample(speechEnd: 0.6, audio: 44))
        #expect(counter.count(audio: LatencyCounter.short) == 2)
        #expect(counter.count(audio: LatencyCounter.long) == 1)
        #expect(counter.median(of: .speechEndToText, audio: LatencyCounter.long) == 0.6)
        #expect(counter.median(of: .speechEndToText, audio: LatencyCounter.short) == 0.2)
    }

    @Test func missingTimingsAreLeftOut() {
        var counter = LatencyCounter()
        counter.record(sample(speechEnd: nil, audio: 3))
        counter.record(sample(speechEnd: 0.3, audio: 3))
        #expect(counter.median(of: .speechEndToText) == 0.3)
        #expect(counter.median(of: .keyUpToText) == 0.2)
    }

    @Test func keepsOnlyTheLastOnes() {
        var counter = LatencyCounter()
        for index in 0..<(LatencyCounter.capacity + 50) {
            counter.record(sample(speechEnd: Double(index), audio: 3))
        }
        #expect(counter.count == LatencyCounter.capacity)
        #expect(counter.samples.first?.speechEndToText == 50)
    }
}
