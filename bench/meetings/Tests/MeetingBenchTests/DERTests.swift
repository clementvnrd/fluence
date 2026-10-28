import FluenceMeetingCore
@testable import MeetingBench
import Testing

/// Small cases worked out by hand. Seconds of speaker time throughout.
@Suite struct DERTests {
    func seg(_ s: String, _ a: Double, _ b: Double) -> Segment { Segment(speaker: s, start: a, end: b) }

    @Test func perfectHypothesisUnderOtherNamesScoresZero() {
        let ref = [seg("A", 0, 10), seg("B", 10, 20)]
        let hyp = [seg("S2", 0, 10), seg("S1", 10, 20)]
        let r = DER.score(reference: ref, hypothesis: hyp, collar: 0)
        #expect(r.referenceSpeech == 20)
        #expect(r.errors == 0)
        #expect(r.mapping == ["A": "S2", "B": "S1"])
    }

    @Test func lateTurnChangeIsConfusion() {
        // Hypothesis switches 2 s late: 2 s of B are given to A's voice.
        let ref = [seg("A", 0, 10), seg("B", 10, 20)]
        let hyp = [seg("X", 0, 12), seg("Y", 12, 20)]
        let r = DER.score(reference: ref, hypothesis: hyp, collar: 0)
        #expect(r.confusion == 2)
        #expect(r.missed == 0 && r.falseAlarm == 0)
        #expect(abs(r.der - 0.1) < 1e-12)
    }

    @Test func collarRemovesAQuarterSecondEachSideOfReferenceBoundaries() {
        // Boundaries at 0, 10 and 20 → scored [0.25, 9.75] ∪ [10.25, 19.75] = 19 s;
        // the late switch costs 12 − 10.25 = 1.75 s.
        let ref = [seg("A", 0, 10), seg("B", 10, 20)]
        let hyp = [seg("X", 0, 12), seg("Y", 12, 20)]
        let r = DER.score(reference: ref, hypothesis: hyp, uem: [(0, 20)], collar: 0.25)
        #expect(abs(r.referenceSpeech - 19) < 1e-9)
        #expect(abs(r.confusion - 1.75) < 1e-9)
        #expect(abs(r.der - 1.75 / 19) < 1e-12)
    }

    @Test func overlappedSpeechIsScored() {
        // A 0–10, B 5–10 (overlap). One hypothesis voice 0–10: 5 s of B missed.
        let ref = [seg("A", 0, 10), seg("B", 5, 10)]
        let hyp = [seg("X", 0, 10)]
        let r = DER.score(reference: ref, hypothesis: hyp, collar: 0)
        #expect(r.referenceSpeech == 15)
        #expect(r.missed == 5)
        #expect(r.confusion == 0)
        #expect(abs(r.der - 5.0 / 15) < 1e-12)
    }

    @Test func speechOutsideTheReferenceIsFalseAlarmAndGapsAreMissed() {
        let ref = [seg("A", 0, 10)]
        let hyp = [seg("X", 2, 13)]
        let r = DER.score(reference: ref, hypothesis: hyp, collar: 0)
        #expect(r.missed == 2)
        #expect(r.falseAlarm == 3)
        #expect(r.confusion == 0)
        #expect(abs(r.der - 0.5) < 1e-12)
    }

    @Test func mappingIsOptimalNotGreedy() {
        // Co-active time: A·X 5, A·Y 4, B·X 4, B·Y 0. Greedy (A→X) keeps 5 s correct;
        // the optimal one-to-one mapping (A→Y, B→X) keeps 8 s. Confusion = 13 − 8.
        let ref = [seg("A", 0, 9), seg("B", 9, 13)]
        let hyp = [seg("X", 0, 5), seg("Y", 5, 9), seg("X", 9, 13)]
        let r = DER.score(reference: ref, hypothesis: hyp, collar: 0)
        #expect(r.mapping == ["A": "Y", "B": "X"])
        #expect(r.confusion == 5)
        #expect(abs(r.der - 5.0 / 13) < 1e-12)
    }

    @Test func extraVoicesCountAsConfusionNotFalseAlarm() {
        // One person split in two voices: the second half is confusion.
        let ref = [seg("A", 0, 20)]
        let hyp = [seg("X", 0, 12), seg("Y", 12, 20)]
        let r = DER.score(reference: ref, hypothesis: hyp, collar: 0)
        #expect(r.confusion == 8)
        #expect(r.falseAlarm == 0)
        #expect(r.hypothesisSpeakers == 2)
    }

    @Test func moreReferenceSpeakersThanVoicesMapsOneAndConfusesTheRest() {
        // One voice for three people, 10 s each: one person maps, 20 s are confusion.
        let ref = [seg("A", 0, 10), seg("B", 10, 20), seg("C", 20, 30)]
        let r = DER.score(reference: ref, hypothesis: [seg("X", 0, 30)], collar: 0)
        #expect(r.mapping.count == 1)
        #expect(r.confusion == 20 && r.missed == 0 && r.falseAlarm == 0)
    }

    @Test func moreVoicesThanReferenceSpeakersConfusesTheUnmapped() {
        let ref = [seg("A", 0, 30)]
        let hyp = [seg("X", 0, 10), seg("Y", 10, 20), seg("Z", 20, 30)]
        let r = DER.score(reference: ref, hypothesis: hyp, collar: 0)
        #expect(r.confusion == 20 && r.falseAlarm == 0)
    }

    @Test func collarAlsoAppliesAroundOverlappedSpeech() {
        // A 0–10, B 4–6 over A; one voice 0–10. Collars at 0, 4, 6, 10 leave
        // [0.25, 3.75] ∪ [4.25, 5.75] ∪ [6.25, 9.75]: A 8.5 s + B 1.5 s, B's 1.5 s missed.
        let ref = [seg("A", 0, 10), seg("B", 4, 6)]
        let r = DER.score(reference: ref, hypothesis: [seg("X", 0, 10)], uem: [(0, 10)], collar: 0.25)
        #expect(abs(r.referenceSpeech - 10) < 1e-9)
        #expect(abs(r.missed - 1.5) < 1e-9)
        #expect(abs(r.der - 0.15) < 1e-12)
    }

    @Test func partialWindowCapIsOneOnMainAndNoneOnTheBranch() {
        #expect(Variant.mainPartialWindow.cap(trueCount: 4) == 1)
        #expect(Variant.branchPartialWindow.cap(trueCount: 4) == nil)
        #expect(Variant.appCap.cap(trueCount: 4) == 4)
    }

    @Test func uemLimitsScoring() {
        let ref = [seg("A", 0, 10)]
        let hyp = [seg("X", 0, 10), seg("X", 30, 40)]
        let r = DER.score(reference: ref, hypothesis: hyp, uem: [(0, 20)], collar: 0)
        #expect(r.falseAlarm == 0)
        #expect(r.errors == 0)
    }

    @Test func pooledRateIsTimeWeighted() {
        let a = DER.score(reference: [seg("A", 0, 10)], hypothesis: [seg("X", 0, 9)], collar: 0)    // 1/10
        let b = DER.score(reference: [seg("A", 0, 30)], hypothesis: [seg("X", 0, 30)], collar: 0)   // 0/30
        #expect(abs((a + b).der - 1.0 / 40) < 1e-12)
    }

    @Test func countError() {
        let c = CountError(reference: 4, hypothesis: 6)
        #expect(c.signed == 2 && c.absolute == 2)
        #expect(CountError(reference: 4, hypothesis: 3).signed == -1)
    }

    @Test func rttmAndUemParse() {
        let rttm = """
        SPEAKER M1 1 34.27 10.12 <NA> <NA> P1 <NA> <NA>
        SPEAKER M1 1 46.43 1.5 <NA> <NA> P2 <NA> <NA>
        """
        let segments = RTTM.parse(rttm)
        #expect(segments.count == 2)
        #expect(segments[0] == Segment(speaker: "P1", start: 34.27, end: 34.27 + 10.12))
        let uem = RTTM.parseUEM("M1 1 0.000 1113.845375\n")
        #expect(uem.count == 1 && uem[0].1 == 1113.845375)
    }

    @Test func majorityReferenceAndPurity() {
        let ref = [seg("A", 0, 10), seg("B", 10, 20)]
        let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 8), SpeakerTurn(speaker: "S1", start: 10, end: 12)]
        let m = Bench.majorityReference(turns: turns, reference: ref)
        #expect(m["S1"]?.speaker == "A")
        #expect(abs((m["S1"]?.purity ?? 0) - 0.8) < 1e-12)
    }
}
