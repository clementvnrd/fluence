import FluenceMeetingCore
import Foundation

/// One meeting of the bench, as listed in `meetings.json`.
public struct MeetingEntry: Codable, Sendable {
    public var id: String
    /// `dev` (calibration) or `test` (report).
    public var split: String
    /// People who speak in the reference (`only_words` RTTM).
    public var speakers: Int
    public var audioSeconds: Double?
    /// SHA-256 of `<id>.Mix-Headset.wav` as downloaded from the AMI mirror.
    public var wavSHA256: String?
    /// SHA-256 of the reference RTTM in pyannote/AMI-diarization-setup.
    public var rttmSHA256: String?
}

public struct Manifest: Codable, Sendable {
    public var meetings: [MeetingEntry]
}

/// The diarizer's raw output for one configuration, cached so the sweep reruns only
/// the consolidation.
public struct DiarizerRun: Codable, Sendable {
    /// `OfflineDiarizerConfig.clustering.maxSpeakers`, as the app sets it from the cap.
    public var maxSpeakers: Int?
    public var turns: [SpeakerTurn]
    /// `DiarizationResult.speakerDatabase`: voice → embedding, what the app consolidates.
    public var embeddings: [String: [Float]]
    public var clusterSeconds: Double

    public init(maxSpeakers: Int?, turns: [SpeakerTurn], embeddings: [String: [Float]], clusterSeconds: Double) {
        self.maxSpeakers = maxSpeakers
        self.turns = turns
        self.embeddings = embeddings
        self.clusterSeconds = clusterSeconds
    }
}

public struct DiarizedMeeting: Codable, Sendable {
    public var id: String
    public var audioSeconds: Double
    public var prepareSeconds: Double
    public var fluidAudioVersion: String
    /// `nocap` (no names known: the app's default) and `cap` (maxSpeakers = true count).
    public var runs: [String: DiarizerRun]

    public init(id: String, audioSeconds: Double, prepareSeconds: Double, fluidAudioVersion: String, runs: [String: DiarizerRun]) {
        self.id = id
        self.audioSeconds = audioSeconds
        self.prepareSeconds = prepareSeconds
        self.fluidAudioVersion = fluidAudioVersion
        self.runs = runs
    }
}

/// What runs between the diarizer and the score.
public enum Variant: String, Codable, Sendable, CaseIterable {
    /// Diarizer as configured when nothing is known, no consolidation.
    case rawNoCap = "raw, no cap"
    /// The app when no names are known: default diarizer + consolidation(cap: nil).
    case appNoCap = "app, no cap"
    /// Diarizer with maxSpeakers = true count, no consolidation.
    case rawCap = "raw, cap = N"
    /// The app when the call shows every participant: maxSpeakers = cap + consolidation(cap).
    case appCap = "app, cap = N"

    /// FLU-33: the call window showed one name of a bigger call, a list cut short.
    /// `fluence/main` (68a7309) took it as the cap: `speakerCap(windowParticipants: 1, …)`.
    case mainPartialWindow = "main, window lists 1 name"
    /// This branch: the list does not look complete, so `ParticipantRoster` gives no cap.
    case branchPartialWindow = "branch, window lists 1 name"

    // main also sets the diarizer's maxSpeakers = 1 there; the consolidation's cap of 1 folds
    // every voice into one either way, and segmentation does not depend on it.
    public var runKey: String { self == .rawCap || self == .appCap ? "cap" : "nocap" }
    public var consolidates: Bool { self != .rawNoCap && self != .rawCap }

    /// The cap the app's own code derives for this situation.
    public func cap(trueCount: Int) -> Int? {
        switch self {
        case .rawCap, .appCap: trueCount
        case .mainPartialWindow: SpeakerConsolidation.speakerCap(windowParticipants: 1, attendees: 0)
        case .branchPartialWindow:
            SpeakerConsolidation.speakerCap(roster: ParticipantRoster(reads: Array(repeating: Self.partialRead, count: 2)), attendees: 0)
        case .rawNoCap, .appNoCap: nil
        }
    }

    static let partialRead = ParticipantRead(names: ["Participant"], complete: false)
}

public struct MeetingScore: Codable, Sendable {
    public var id: String
    public var split: String
    public var der: DER.Result
    public var derNoCollar: DER.Result
    public var count: CountError
}

public struct PooledScore: Codable, Sendable {
    public var meetings: Int
    public var der: Double
    public var derNoCollar: Double
    public var missed: Double
    public var falseAlarm: Double
    public var confusion: Double
    public var meanAbsoluteCountError: Double
    public var meanSignedCountError: Double
    public var exactCount: Int

    public init(_ scores: [MeetingScore]) {
        let pooled = scores.map(\.der).reduce(DER.Result.zero, +)
        let strict = scores.map(\.derNoCollar).reduce(DER.Result.zero, +)
        meetings = scores.count
        der = pooled.der
        derNoCollar = strict.der
        let speech = max(pooled.referenceSpeech, .leastNonzeroMagnitude)
        missed = pooled.missed / speech
        falseAlarm = pooled.falseAlarm / speech
        confusion = pooled.confusion / speech
        let n = Double(max(scores.count, 1))
        meanAbsoluteCountError = Double(scores.map(\.count.absolute).reduce(0, +)) / n
        meanSignedCountError = Double(scores.map(\.count.signed).reduce(0, +)) / n
        exactCount = scores.filter { $0.count.signed == 0 }.count
    }
}

public enum Bench {
    /// The hypothesis turns for one variant: exactly the calls `MeetingFinalizer.attribute`
    /// makes after the diarizer (`SpeakerConsolidation.consolidate(turns:embeddings:cap:)`).
    public static func hypothesis(
        _ meeting: DiarizedMeeting,
        variant: Variant,
        trueCount: Int,
        settings: SpeakerConsolidation.Settings = .init()
    ) -> [SpeakerTurn] {
        guard let run = meeting.runs[variant.runKey] else { return [] }
        guard variant.consolidates else { return run.turns }
        let cap = variant.cap(trueCount: trueCount)
        return SpeakerConsolidation.consolidate(
            turns: run.turns, embeddings: run.embeddings, cap: cap, settings: settings
        ).turns
    }

    public static func score(
        entry: MeetingEntry,
        reference: [Segment],
        uem: [(Double, Double)]?,
        hypothesis: [SpeakerTurn]
    ) -> MeetingScore {
        let hyp = hypothesis.map { Segment(speaker: $0.speaker, start: $0.start, end: $0.end) }
        let der = DER.score(reference: reference, hypothesis: hyp, uem: uem, collar: 0.25)
        let strict = DER.score(reference: reference, hypothesis: hyp, uem: uem, collar: 0)
        let count = CountError(reference: Set(reference.map(\.speaker)).count,
                               hypothesis: Set(hypothesis.map(\.speaker)).count)
        return MeetingScore(id: entry.id, split: entry.split, der: der, derNoCollar: strict, count: count)
    }

    /// Each voice → the reference speaker it overlaps most (nil if it overlaps none), and
    /// that share of its speech (purity).
    public static func majorityReference(
        turns: [SpeakerTurn], reference: [Segment]
    ) -> [String: (speaker: String?, purity: Double, seconds: Double)] {
        let ref = DER.mergedBySpeaker(reference)
        var out: [String: (String?, Double, Double)] = [:]
        for (voice, voiceTurns) in Dictionary(grouping: turns, by: \.speaker) {
            let own = DER.union(voiceTurns.map { ($0.start, $0.end) })
            let seconds = own.reduce(0) { $0 + $1.1 - $1.0 }
            var best: (String, Double)?
            for (name, intervals) in ref {
                let shared = intersection(own, intervals)
                if shared > 0, best == nil || shared > best!.1 { best = (name, shared) }
            }
            out[voice] = (best?.0, seconds > 0 ? (best?.1 ?? 0) / seconds : 0, seconds)
        }
        return out.mapValues { (speaker: $0.0, purity: $0.1, seconds: $0.2) }
    }

    static func intersection(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> Double {
        var i = 0, j = 0, total = 0.0
        while i < a.count, j < b.count {
            let s = max(a[i].0, b[j].0), e = min(a[i].1, b[j].1)
            if e > s { total += e - s }
            if a[i].1 < b[j].1 { i += 1 } else { j += 1 }
        }
        return total
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a, b) {
            dot += Double(x) * Double(y); na += Double(x) * Double(x); nb += Double(y) * Double(y)
        }
        guard na > 0, nb > 0 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
