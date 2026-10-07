import Foundation
import Testing

@testable import FluenceCore

struct AudioLevelTests {
    /// A 220 Hz sine whose RMS is `dbfs`.
    private func tone(dbfs: Float, count: Int = 2_048) -> [Float] {
        let rms = pow(10, dbfs / 20)
        let peak = rms * Float(2).squareRoot()
        return (0..<count).map { peak * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    @Test func silenceIsFlat() {
        #expect(AudioLevel.level([Float](repeating: 0, count: 1_024)) == 0)
        #expect(AudioLevel.level([]) == 0)
    }

    @Test func roomNoiseIsFlat() {
        #expect(AudioLevel.level(tone(dbfs: -60)) == 0)
        #expect(AudioLevel.level(tone(dbfs: -53)) == 0)
    }

    @Test func speechFillsTheBars() {
        let middle = AudioLevel.level(tone(dbfs: -32))
        #expect(abs(middle - 0.5) < 0.02)
        #expect(AudioLevel.level(tone(dbfs: -12)) > 0.98)
        #expect(AudioLevel.level(tone(dbfs: -3)) == 1)
    }

    @Test func louderIsHigher() {
        let levels = [-50, -40, -30, -20].map { AudioLevel.level(tone(dbfs: Float($0))) }
        #expect(levels == levels.sorted())
        #expect(Set(levels).count == levels.count)
    }

    @Test func followerRisesFastAndFallsSlowly() {
        var follower = LevelFollower(attack: 0.05, release: 0.3)
        // One time constant: about 63 % of the way.
        follower.update(target: 1, dt: 0.05)
        #expect(abs(follower.value - 0.632) < 0.01)
        follower.update(target: 1, dt: 0.5)
        #expect(follower.value > 0.99)

        follower.update(target: 0, dt: 0.05)
        let afterShortSilence = follower.value
        #expect(afterShortSilence > 0.8)  // a pause between words keeps the bars up
        follower.update(target: 0, dt: 2)
        #expect(follower.value == 0)  // and real silence brings them all the way down
    }

    @Test func followerDoesNotDependOnBufferSize() {
        var coarse = LevelFollower()
        var fine = LevelFollower()
        coarse.update(target: 0.8, dt: 0.128)
        for _ in 0..<16 { fine.update(target: 0.8, dt: 0.008) }
        #expect(abs(coarse.value - fine.value) < 0.001)
    }
}
