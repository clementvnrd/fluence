import Testing

@testable import FluenceCore

/// The level waveform, with and without Reduce Motion (FLU-38).
struct WaveBarsTests {
    static func heights(level: Double?, time: Double, reduceMotion: Bool) -> [Double] {
        (0..<7).map {
            WaveBars.height(index: $0, count: 7, level: level, isActive: true, time: time, maxHeight: 18, reduceMotion: reduceMotion)
        }
    }

    @Test("without Reduce Motion the bars ripple over time")
    func ripples() {
        #expect(Self.heights(level: 0.6, time: 0, reduceMotion: false) != Self.heights(level: 0.6, time: 0.3, reduceMotion: false))
        #expect(Self.heights(level: nil, time: 0, reduceMotion: false) != Self.heights(level: nil, time: 0.3, reduceMotion: false))
    }

    @Test("with Reduce Motion nothing moves on its own", arguments: [nil, 0.0, 0.3, 1.0] as [Double?])
    func stillWithReduceMotion(level: Double?) {
        let first = Self.heights(level: level, time: 0, reduceMotion: true)
        for time in [0.1, 0.25, 1.7, 42.0] {
            #expect(Self.heights(level: level, time: time, reduceMotion: true) == first)
        }
    }

    @Test("with Reduce Motion the bars still follow the voice")
    func followsLevel() {
        let quiet = Self.heights(level: 0.1, time: 0, reduceMotion: true)
        let loud = Self.heights(level: 0.9, time: 0, reduceMotion: true)
        #expect(zip(quiet, loud).allSatisfy { $0 < $1 })
    }

    @Test("silence and an idle wave are flat")
    func flat() {
        #expect(Self.heights(level: 0, time: 3, reduceMotion: false).allSatisfy { $0 == WaveBars.floor })
        let idle = WaveBars.height(index: 2, count: 7, level: 0.8, isActive: false, time: 3, maxHeight: 18, reduceMotion: false)
        #expect(idle == WaveBars.floor)
    }

    @Test("a bar never grows past its maximum")
    func capped() {
        for time in stride(from: 0.0, to: 2, by: 0.05) {
            #expect(Self.heights(level: 1, time: time, reduceMotion: false).allSatisfy { $0 <= 18 })
        }
    }
}
