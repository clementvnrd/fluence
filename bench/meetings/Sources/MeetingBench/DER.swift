import FluenceMeetingCore
import Foundation

/// One speaker active over [start, end), seconds from the start of the recording.
public struct Segment: Codable, Sendable, Hashable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Diarization error rate, the md-eval / dscore way:
///
/// - Scored time is the UEM minus a no-score zone of ±`collar` seconds around every
///   reference boundary (each speaker's turns merged first, so touching words of one
///   speaker make no boundary).
/// - Overlapped speech is scored: over each stretch, with `nRef` reference and `nHyp`
///   hypothesis speakers active, missed = max(0, nRef − nHyp), false alarm =
///   max(0, nHyp − nRef), confusion = min(nRef, nHyp) − correctly mapped speakers.
/// - The reference ↔ hypothesis speaker mapping is one-to-one and maximises the total
///   co-active time (Hungarian, `FluenceMeetingCore.Hungarian`).
/// - DER = (missed + false alarm + confusion) / total reference speech, all in seconds
///   of speaker time.
public enum DER {
    public struct Result: Codable, Sendable, Equatable {
        public var referenceSpeech: Double
        public var missed: Double
        public var falseAlarm: Double
        public var confusion: Double
        /// Reference speaker → hypothesis speaker (unmapped speakers are absent).
        public var mapping: [String: String]
        public var referenceSpeakers: Int
        public var hypothesisSpeakers: Int

        public var errors: Double { missed + falseAlarm + confusion }
        public var der: Double { referenceSpeech > 0 ? errors / referenceSpeech : 0 }

        public static let zero = Result(referenceSpeech: 0, missed: 0, falseAlarm: 0, confusion: 0,
                                        mapping: [:], referenceSpeakers: 0, hypothesisSpeakers: 0)

        /// Pooled over meetings: seconds add up, the rate is recomputed (time-weighted).
        public static func + (a: Result, b: Result) -> Result {
            Result(referenceSpeech: a.referenceSpeech + b.referenceSpeech, missed: a.missed + b.missed,
                   falseAlarm: a.falseAlarm + b.falseAlarm, confusion: a.confusion + b.confusion,
                   mapping: [:], referenceSpeakers: a.referenceSpeakers + b.referenceSpeakers,
                   hypothesisSpeakers: a.hypothesisSpeakers + b.hypothesisSpeakers)
        }
    }

    /// - Parameters:
    ///   - uem: scored regions; nil scores from 0 to the last boundary of either side.
    ///   - collar: seconds on *each* side of a reference boundary (md-eval `-c`).
    public static func score(
        reference: [Segment],
        hypothesis: [Segment],
        uem: [(Double, Double)]? = nil,
        collar: Double = 0.25
    ) -> Result {
        let ref = mergedBySpeaker(reference)
        let hyp = mergedBySpeaker(hypothesis)
        let refNames = ref.keys.sorted()
        let hypNames = hyp.keys.sorted()

        let end = (reference + hypothesis).map(\.end).max() ?? 0
        var scored = union(uem ?? [(0, end)])
        if collar > 0 {
            var zones: [(Double, Double)] = []
            for intervals in ref.values {
                for (s, e) in intervals {
                    zones.append((s - collar, s + collar))
                    zones.append((e - collar, e + collar))
                }
            }
            scored = subtract(scored, union(zones))
        }

        // Sweep: kind 0 = scored region, 1 = reference speaker, 2 = hypothesis speaker.
        struct Event { var time: Double; var kind: Int; var index: Int; var delta: Int }
        var events: [Event] = []
        for (s, e) in scored where e > s {
            events.append(Event(time: s, kind: 0, index: 0, delta: 1))
            events.append(Event(time: e, kind: 0, index: 0, delta: -1))
        }
        for (i, name) in refNames.enumerated() {
            for (s, e) in ref[name]! where e > s {
                events.append(Event(time: s, kind: 1, index: i, delta: 1))
                events.append(Event(time: e, kind: 1, index: i, delta: -1))
            }
        }
        for (j, name) in hypNames.enumerated() {
            for (s, e) in hyp[name]! where e > s {
                events.append(Event(time: s, kind: 2, index: j, delta: 1))
                events.append(Event(time: e, kind: 2, index: j, delta: -1))
            }
        }
        events.sort { $0.time < $1.time }

        var scoredDepth = 0
        var refActive = [Int](repeating: 0, count: refNames.count)
        var hypActive = [Int](repeating: 0, count: hypNames.count)
        var overlap = [[Double]](repeating: [Double](repeating: 0, count: hypNames.count), count: refNames.count)
        var total = 0.0, missed = 0.0, falseAlarm = 0.0, matchable = 0.0
        var previous = events.first?.time ?? 0
        var k = 0
        while k < events.count {
            let now = events[k].time
            let duration = now - previous
            if duration > 0, scoredDepth > 0 {
                let activeRef = refActive.indices.filter { refActive[$0] > 0 }
                let activeHyp = hypActive.indices.filter { hypActive[$0] > 0 }
                let nRef = Double(activeRef.count), nHyp = Double(activeHyp.count)
                total += nRef * duration
                missed += max(0, nRef - nHyp) * duration
                falseAlarm += max(0, nHyp - nRef) * duration
                matchable += min(nRef, nHyp) * duration
                for i in activeRef { for j in activeHyp { overlap[i][j] += duration } }
            }
            while k < events.count, events[k].time == now {
                let event = events[k]
                switch event.kind {
                case 0: scoredDepth += event.delta
                case 1: refActive[event.index] += event.delta
                default: hypActive[event.index] += event.delta
                }
                k += 1
            }
            previous = now
        }

        var mapping: [String: String] = [:]
        var correct = 0.0
        if !refNames.isEmpty, !hypNames.isEmpty {
            let assignment = Hungarian.assign(overlap.map { $0.map { -$0 } })
            for (i, column) in assignment.enumerated() {
                guard let j = column, overlap[i][j] > 0 else { continue }
                mapping[refNames[i]] = hypNames[j]
                correct += overlap[i][j]
            }
        }
        return Result(referenceSpeech: total, missed: missed, falseAlarm: falseAlarm,
                      confusion: max(0, matchable - correct), mapping: mapping,
                      referenceSpeakers: refNames.count, hypothesisSpeakers: hypNames.count)
    }

    // MARK: - Interval helpers

    static func mergedBySpeaker(_ segments: [Segment]) -> [String: [(Double, Double)]] {
        Dictionary(grouping: segments, by: \.speaker).mapValues { union($0.map { ($0.start, $0.end) }) }
    }

    /// Sorted union; touching intervals join.
    static func union(_ intervals: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for (s, e) in intervals.filter({ $0.1 > $0.0 }).sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, s <= last.1 {
                out[out.count - 1].1 = max(last.1, e)
            } else {
                out.append((s, e))
            }
        }
        return out
    }

    /// `a` minus `b`, both sorted unions.
    static func subtract(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for (s0, e0) in a {
            var s = s0
            for (bs, be) in b where be > s && bs < e0 {
                if bs > s { out.append((s, bs)) }
                s = max(s, be)
                if s >= e0 { break }
            }
            if s < e0 { out.append((s, e0)) }
        }
        return out
    }
}

/// Speaker count: how many distinct voices the pipeline kept vs how many people spoke.
public struct CountError: Codable, Sendable, Equatable {
    public var reference: Int
    public var hypothesis: Int
    public var signed: Int { hypothesis - reference }
    public var absolute: Int { abs(signed) }

    public init(reference: Int, hypothesis: Int) {
        self.reference = reference
        self.hypothesis = hypothesis
    }
}

public enum RTTM {
    /// `SPEAKER <file> <chan> <start> <duration> <NA> <NA> <speaker> <NA> <NA>`
    public static func parse(_ text: String) -> [Segment] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count >= 8, f[0] == "SPEAKER", let start = Double(f[3]), let duration = Double(f[4]) else { return nil }
            return Segment(speaker: String(f[7]), start: start, end: start + duration)
        }
    }

    /// `<file> <chan> <start> <end>`
    public static func parseUEM(_ text: String) -> [(Double, Double)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count >= 4, let s = Double(f[2]), let e = Double(f[3]) else { return nil }
            return (s, e)
        }
    }
}
