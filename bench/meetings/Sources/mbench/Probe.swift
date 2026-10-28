import FluenceMeetingCore
import Foundation
import MeetingBench

/// Checks the claims written in SpeakerConsolidation.Settings against real embeddings:
/// "The diarizer itself stops merging around 0.82 (euclidean 0.6 on unit vectors); VoIP
/// splits of one voice typically sit between 0.65 and 0.8, different people below 0.5."
///
/// Pairs of the diarizer's raw voices (no cap) in each meeting, labelled by the reference
/// speaker each voice overlaps most: "same person" (an over-split) or "different people".
struct Probe: Codable {
    struct Stats: Codable {
        var count: Int
        var min: Double?
        var p10: Double?
        var median: Double?
        var p90: Double?
        var max: Double?

        init(_ values: [Double]) {
            let v = values.sorted()
            count = v.count
            func q(_ p: Double) -> Double? { v.isEmpty ? nil : v[Swift.min(v.count - 1, Int((Double(v.count - 1) * p).rounded()))] }
            self.min = v.first; p10 = q(0.1); median = q(0.5); p90 = q(0.9); self.max = v.last
        }
    }

    var embeddingDimension: Int
    var samePerson: Stats
    var differentPeople: Stats
    var differentAtOrAbove050: Int
    var differentAtOrAbove068: Int
    var sameAtOrAbove068: Int
    var sameIn065to080: Int
    var anyPairAbove082: Int
    /// Raw voices (no cap) whose majority reference speaker covers < 50 % of their speech.
    var impureVoices: Int
    var rawVoices: Int
    /// Raw voices with < 8 s of speech, and how many of those belong (by majority) to a
    /// reference speaker who also has a bigger voice — i.e. a fragment the minor rule should absorb.
    var minorVoices: Int
    var minorVoicesThatAreFragments: Int
    /// meeting → (reference speakers, raw voices no cap, raw voices with maxSpeakers = N).
    var voices: [String: [Int]]

    static func measure(_ meetings: [(MeetingEntry, DiarizedMeeting, [Segment])]) -> Probe {
        var same: [Double] = [], different: [Double] = []
        var dimension = 0, impure = 0, raw = 0, minor = 0, fragments = 0
        var voices: [String: [Int]] = [:]
        for (entry, meeting, reference) in meetings {
            guard let run = meeting.runs["nocap"] else { continue }
            voices[entry.id] = [Set(reference.map(\.speaker)).count, Set(run.turns.map(\.speaker)).count,
                                Set(meeting.runs["cap"]?.turns.map(\.speaker) ?? []).count]
            let majority = Bench.majorityReference(turns: run.turns, reference: reference)
            let ids = majority.keys.sorted()
            raw += ids.count
            impure += ids.filter { (majority[$0]?.purity ?? 0) < 0.5 }.count
            for id in ids where (majority[id]?.seconds ?? 0) < 8 {
                minor += 1
                let owner = majority[id]?.speaker
                if owner != nil, ids.contains(where: { $0 != id && majority[$0]?.speaker == owner && (majority[$0]?.seconds ?? 0) > (majority[id]?.seconds ?? 0) }) {
                    fragments += 1
                }
            }
            for i in ids.indices {
                for j in ids.indices where j > i {
                    guard let a = run.embeddings[ids[i]], let b = run.embeddings[ids[j]],
                          let c = Bench.cosine(a, b),
                          let ra = majority[ids[i]]?.speaker, let rb = majority[ids[j]]?.speaker else { continue }
                    dimension = a.count
                    if ra == rb { same.append(c) } else { different.append(c) }
                }
            }
        }
        return Probe(
            embeddingDimension: dimension, samePerson: Stats(same), differentPeople: Stats(different),
            differentAtOrAbove050: different.filter { $0 >= 0.5 }.count,
            differentAtOrAbove068: different.filter { $0 >= 0.68 }.count,
            sameAtOrAbove068: same.filter { $0 >= 0.68 }.count,
            sameIn065to080: same.filter { $0 >= 0.65 && $0 <= 0.8 }.count,
            anyPairAbove082: (same + different).filter { $0 > 0.82 }.count,
            impureVoices: impure, rawVoices: raw, minorVoices: minor, minorVoicesThatAreFragments: fragments,
            voices: voices
        )
    }
}
