import Foundation

/// Merges the microphone and system transcripts into one time-ordered list, dropping mic
/// segments that are only the loudspeaker's echo of the remote side.
///
/// Contract: Tests/FluenceMeetingCoreTests/meeting-test-vectors.json, `merge`.
///
/// **Echo backstop.** On speakers the mic hears the remote side, so the same words come
/// back attributed to "me". The echo canceller removes most of it; this catches the rest.
/// A mic segment is dropped when its normalised tokens (see `TextTokens`) match the system
/// tokens spoken at the same time:
///
/// - A = the mic segment's token set. Empty A is always kept.
/// - Every system token carries a time: the midpoint of its word, or — for a segment with
///   no word timings — the midpoint of an even split of the segment span across its tokens.
/// - For each shift d = −1.5 s, −1.4 s, … +1.5 s (31 steps of 0.1 s, `k = 0…30`,
///   `d = (k − 15) / 10`), B(d) = the set of system tokens whose time t satisfies
///   `mic.start + d − 0.25 ≤ t ≤ mic.end + d + 0.25`.
/// - The mic segment is dropped when `max over d of Jaccard(A, B(d)) > 0.6`.
///
/// Shifting a window the size of the mic segment, rather than widening it by ±1.5 s, is
/// deliberate: widening pulls in neighbouring remote words and dilutes the score, so a
/// genuine echo inside continuous remote speech would survive.
///
/// **Order.** Kept segments are sorted by start time; on a tie the microphone comes first,
/// then the earlier end, then the original order.
public enum TranscriptMerger {
    public static let jaccardThreshold = 0.6
    public static let maxShift: TimeInterval = 1.5
    public static let shiftStep: TimeInterval = 0.1
    public static let edgeTolerance: TimeInterval = 0.25

    public static func merge(
        microphone: [TranscriptSegment],
        system: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let systemTokens = timedTokens(system)
        let kept = microphone.filter { !isEcho($0, systemTokens: systemTokens) }
        return sorted(kept + system)
    }

    /// Whether `mic` duplicates what the system stream said around the same time.
    public static func isEcho(_ mic: TranscriptSegment, system: [TranscriptSegment]) -> Bool {
        isEcho(mic, systemTokens: timedTokens(system))
    }

    public static func sorted(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if a.start != b.start { return a.start < b.start }
            if a.source != b.source { return a.source == .microphone }
            if a.end != b.end { return a.end < b.end }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: - Internals

    struct TimedToken {
        let token: String
        let time: TimeInterval
    }

    static func timedTokens(_ segments: [TranscriptSegment]) -> [TimedToken] {
        var result: [TimedToken] = []
        for segment in segments {
            if segment.words.isEmpty {
                let tokens = TextTokens.normalize(segment.text)
                guard !tokens.isEmpty else { continue }
                let step = (segment.end - segment.start) / Double(tokens.count)
                for (index, token) in tokens.enumerated() {
                    result.append(TimedToken(token: token, time: segment.start + (Double(index) + 0.5) * step))
                }
            } else {
                for word in segment.words {
                    let time = (word.start + word.end) / 2
                    for token in TextTokens.normalize(word.text) {
                        result.append(TimedToken(token: token, time: time))
                    }
                }
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    static func isEcho(_ mic: TranscriptSegment, systemTokens: [TimedToken]) -> Bool {
        let a = Set(TextTokens.normalize(mic.text))
        guard !a.isEmpty else { return false }

        // Only tokens that any shift could reach.
        let low = mic.start - maxShift - edgeTolerance
        let high = mic.end + maxShift + edgeTolerance
        // Tokens are sorted by time: binary-search the window instead of scanning a
        // three-hour meeting for every mic segment.
        var first = 0, last = systemTokens.count
        while first < last {
            let middle = (first + last) / 2
            if systemTokens[middle].time < low { first = middle + 1 } else { last = middle }
        }
        var nearby: [TimedToken] = []
        var index = first
        while index < systemTokens.count, systemTokens[index].time <= high {
            nearby.append(systemTokens[index])
            index += 1
        }
        guard !nearby.isEmpty else { return false }

        let steps = Int((2 * maxShift / shiftStep).rounded())
        for k in 0...steps {
            let shift = Double(k - steps / 2) / 10
            let lower = mic.start + shift - edgeTolerance
            let upper = mic.end + shift + edgeTolerance
            let b = Set(nearby.lazy.filter { $0.time >= lower && $0.time <= upper }.map(\.token))
            if TextTokens.jaccard(a, b) > jaccardThreshold { return true }
        }
        return false
    }
}
