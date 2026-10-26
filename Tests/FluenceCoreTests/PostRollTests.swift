import Foundation
import Testing

@testable import FluenceCore

/// FLU-31: the post-roll ends early only when the audio proves the speaker had finished.
struct PostRollTests {
    private let rate = 48_000.0
    private let start = 1_000.0  // host seconds; any origin

    /// `seconds` of a 220 Hz tone at `amplitude`, observed in `chunk`-frame buffers starting at
    /// `at`. Returns where it ended.
    @discardableResult
    private func observe(
        _ trail: inout TrailingSilence,
        seconds: Double,
        amplitude: Float,
        at: Double,
        chunk: Int = 4_800
    ) -> Double {
        let total = Int(seconds * rate)
        var produced = 0
        while produced < total {
            let count = min(chunk, total - produced)
            let samples = (0..<count).map { index in
                amplitude * sin(Float(produced + index) * 2 * .pi * 220 / Float(rate))
            }
            trail.observe(samples, sampleRate: rate, startTime: at + Double(produced) / rate)
            produced += count
        }
        return at + Double(total) / rate
    }

    private let speech: Float = 0.1      // about -23 dBFS RMS
    private let roomTone: Float = 0.0005 // about -69 dBFS RMS

    // MARK: TrailingSilence

    @Test func findsWhereTheLastSoundEnded() {
        var trail = TrailingSilence()
        let spoken = observe(&trail, seconds: 1, amplitude: speech, at: start)
        observe(&trail, seconds: 0.4, amplitude: roomTone, at: spoken)
        let lastSound = try! #require(trail.snapshot.lastSoundEnd)
        #expect(abs(lastSound - spoken) < 0.021)
        #expect(abs(trail.snapshot.coveredUntil! - (spoken + 0.4)) < 0.021)
    }

    @Test func roomToneHasNoSound() {
        var trail = TrailingSilence()
        observe(&trail, seconds: 1, amplitude: roomTone, at: start)
        #expect(trail.snapshot.lastSoundEnd == nil)
        #expect(trail.snapshot.coveredUntil != nil)
    }

    /// The same quiet signal `SpeechGate` accepts as speech is sound here too.
    @Test func quietSpeechCountsAsSound() {
        var trail = TrailingSilence()
        observe(&trail, seconds: 0.5, amplitude: 0.004, at: start)  // about -51 dBFS RMS
        #expect(trail.snapshot.lastSoundEnd != nil)
    }

    @Test func aWindowAcrossTwoBuffersIsJudgedWhole() {
        var trail = TrailingSilence()
        // 700-frame buffers never line up with 960-frame (20 ms) windows.
        observe(&trail, seconds: 0.3, amplitude: speech, at: start, chunk: 700)
        let covered = try! #require(trail.snapshot.coveredUntil)
        #expect(abs(covered - (start + 0.3)) < 0.021)
        #expect(trail.snapshot.lastSoundEnd == covered)
    }

    @Test func aPartialWindowIsNotJudgedYet() {
        var trail = TrailingSilence()
        observe(&trail, seconds: 0.01, amplitude: speech, at: start)  // half a window
        #expect(trail.snapshot == .init())
    }

    @Test func aGapStartsAFreshWindowWithoutForgettingASound() {
        var trail = TrailingSilence()
        observe(&trail, seconds: 0.01, amplitude: speech, at: start)
        // Half a window of sound, then a gap: the half still counts as sound, and does not
        // spill into the room tone after the gap.
        observe(&trail, seconds: 0.02, amplitude: roomTone, at: start + 1)
        #expect(abs(trail.snapshot.lastSoundEnd! - (start + 0.01)) < 0.001)
        #expect(abs(trail.snapshot.coveredUntil! - (start + 1.02)) < 0.001)
    }

    @Test func aGapAfterRoomToneAddsNoSound() {
        var trail = TrailingSilence()
        observe(&trail, seconds: 0.01, amplitude: roomTone, at: start)
        observe(&trail, seconds: 0.02, amplitude: roomTone, at: start + 1)
        #expect(trail.snapshot.lastSoundEnd == nil)
    }

    @Test func timestampJitterIsNotAGap() {
        var trail = TrailingSilence()
        // 30 ms of sound split 10 + 20 ms, the second buffer stamped 3 ms late: still one stretch.
        observe(&trail, seconds: 0.01, amplitude: speech, at: start)
        observe(&trail, seconds: 0.02, amplitude: speech, at: start + 0.013)
        #expect(abs(trail.snapshot.coveredUntil! - (start + 0.023)) < 0.001)
    }

    @Test func ignoresUnusableBuffers() {
        var trail = TrailingSilence()
        trail.observe([Float](repeating: 0.1, count: 960), sampleRate: 0, startTime: start)
        trail.observe([Float](repeating: 0.1, count: 960), sampleRate: rate, startTime: .nan)
        trail.observe([Float](), sampleRate: rate, startTime: start)
        #expect(trail.snapshot == .init())
    }

    // MARK: Decision

    @Test func silenceBeforeReleaseStopsAsSoonAsTheAudioHasArrived() {
        let release = start + 2
        let trail = TrailingSilence.Snapshot(coveredUntil: release + 0.01, lastSoundEnd: release - 0.3)
        #expect(PostRoll.decide(trail, releasedAt: release, now: release + 0.05) == .stop(.trailingSilence))
    }

    @Test func waitsForTheAudioUpToTheRelease() {
        let release = start + 2
        // Silent so far, but the last 40 ms before the release are still in flight.
        let trail = TrailingSilence.Snapshot(coveredUntil: release - 0.04, lastSoundEnd: release - 1)
        #expect(PostRoll.decide(trail, releasedAt: release, now: release + 0.02) == .wait)
    }

    @Test func soundJustBeforeReleaseKeepsTheFullPostRoll() {
        let release = start + 2
        let trail = TrailingSilence.Snapshot(coveredUntil: release + 0.1, lastSoundEnd: release - 0.1)
        #expect(PostRoll.decide(trail, releasedAt: release, now: release + 0.1) == .wait)
        #expect(PostRoll.decide(trail, releasedAt: release, now: release + 0.249) == .wait)
        #expect(PostRoll.decide(trail, releasedAt: release, now: release + 0.25) == .stop(.elapsed))
    }

    @Test func soundAfterReleaseKeepsTheFullPostRoll() {
        let release = start + 2
        let trail = TrailingSilence.Snapshot(coveredUntil: release + 0.1, lastSoundEnd: release + 0.08)
        #expect(PostRoll.decide(trail, releasedAt: release, now: release + 0.1) == .wait)
    }

    @Test func exactlyTheSilenceSpanIsEnough() {
        let release = start + 2
        let trail = TrailingSilence.Snapshot(coveredUntil: release, lastSoundEnd: release - PostRoll.silence)
        #expect(PostRoll.decide(trail, releasedAt: release, now: release) == .stop(.trailingSilence))
    }

    @Test func nothingHeardAtAllStops() {
        let release = start + 2
        let trail = TrailingSilence.Snapshot(coveredUntil: release + 0.02, lastSoundEnd: nil)
        #expect(PostRoll.decide(trail, releasedAt: release, now: release + 0.03) == .stop(.trailingSilence))
    }

    /// No timing from the capture at all: the old fixed post-roll.
    @Test func noTimingFallsBackToTheFullPostRoll() {
        let release = start + 2
        #expect(PostRoll.decide(.init(), releasedAt: release, now: release + 0.2) == .wait)
        #expect(PostRoll.decide(.init(), releasedAt: release, now: release + 0.25) == .stop(.elapsed))
    }

    /// End to end on synthetic audio: a phrase, a pause, a release.
    @Test func shortPhraseThenPauseThenRelease() {
        var trail = TrailingSilence()
        let spoken = observe(&trail, seconds: 1.5, amplitude: speech, at: start)
        let release = spoken + 0.2
        observe(&trail, seconds: 0.3, amplitude: roomTone, at: spoken)  // the next buffer covers the release
        #expect(PostRoll.decide(trail.snapshot, releasedAt: release, now: release + 0.1) == .stop(.trailingSilence))
    }

    /// The release on the last syllable, the case the post-roll exists for.
    @Test func releaseOnTheLastSyllable() {
        var trail = TrailingSilence()
        let spoken = observe(&trail, seconds: 1.5, amplitude: speech, at: start)
        let release = spoken - 0.05
        observe(&trail, seconds: 0.3, amplitude: roomTone, at: spoken)
        #expect(PostRoll.decide(trail.snapshot, releasedAt: release, now: release + 0.1) == .wait)
        #expect(PostRoll.decide(trail.snapshot, releasedAt: release, now: release + 0.25) == .stop(.elapsed))
    }
}
