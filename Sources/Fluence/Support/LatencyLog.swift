import FluenceCore
import Foundation

/// The timings-only counter of FLU-31: every dictation that types text adds its tail timings,
/// and the log line carries the running medians against the budgets (end of speech → text
/// ≤ 250 ms at the median up to 10 s of speech, ≤ 400 ms for 44 s). Kept in memory, never
/// written to disk, and it never sees a word of the dictation.
@MainActor
enum LatencyLog {
    private static var counter = LatencyCounter()

    static func record(_ sample: DictationLatency) {
        counter.record(sample)
        // Formatted first: the logger's arguments are evaluated outside this actor.
        let speechEnd = milliseconds(sample.speechEndToText)
        let keyUp = milliseconds(sample.keyUpToText)
        let postRoll = milliseconds(sample.postRoll)
        let engine = milliseconds(sample.engine)
        let audio = sample.audioSeconds
        let shortMedian = milliseconds(counter.median(of: .speechEndToText, audio: LatencyCounter.short))
        let shortCount = counter.count(audio: LatencyCounter.short)
        let longMedian = milliseconds(counter.median(of: .speechEndToText, audio: LatencyCounter.long))
        let longCount = counter.count(audio: LatencyCounter.long)
        Log.latency.info("""
            dictation · speech end→text \(speechEnd, privacy: .public) · key-up→text \(keyUp, privacy: .public) · \
            post-roll \(postRoll, privacy: .public) · engine \(engine, privacy: .public) · \
            \(audio, format: .fixed(precision: 1), privacy: .public) s audio · \
            p50 ≤10 s \(shortMedian, privacy: .public) (n=\(shortCount, privacy: .public)) · \
            p50 >10 s \(longMedian, privacy: .public) (n=\(longCount, privacy: .public))
            """)
    }

    private static func milliseconds(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "–" }
        return "\(Int((seconds * 1_000).rounded())) ms"
    }
}
