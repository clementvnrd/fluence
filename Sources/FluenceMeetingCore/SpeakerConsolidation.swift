import Foundation

/// Between the diarizer and the word attribution: fewer, truer voices (FLU-22).
///
/// The diarizer clusters short windows of the call's audio. On compressed VoIP audio —
/// gain control, noise suppression, a network that changes quality mid-call — one person
/// often comes out as two or three clusters, and a cough, a notification or a few words of
/// crosstalk become a "speaker" of their own. Three passes, in order:
///
/// 1. **Merge near-duplicates**: two voices whose embeddings are this similar are one
///    person heard through different conditions.
/// 2. **Absorb minor voices**: a voice that speaks for only a few seconds in the whole
///    meeting joins the closest major voice (by embedding, else the one speaking around it).
/// 3. **Cap**: never more voices than people known to be in the call; the closest pair
///    merges until the count fits. The call window's names count only when its list looks
///    complete (`ParticipantRoster`, FLU-33).
///
/// The larger voice always absorbs the smaller, and its embedding becomes the
/// speech-weighted mean of both. Pure arithmetic, pinned by
/// `Tests/FluenceMeetingCoreTests/speaker-consolidation-vectors.json`.
public enum SpeakerConsolidation {
    public struct Settings: Sendable, Equatable {
        /// Cosine similarity at or above which two voices are the same person. The diarizer
        /// itself stops merging around 0.82 (euclidean 0.6 on unit vectors). Measured on AMI
        /// meetings through a VoIP-like channel (bench/meetings, FLU-33): one person's split
        /// voices sit at 0.53–0.77 (median 0.68), different people mostly below 0.5 but up to
        /// 0.71, so no value separates them all. 0.60 to 0.70 give the same mean DER over the
        /// bench's conditions, and 0.70, best on its dev meetings, lost on its test ones.
        public var mergeSimilarity: Double = 0.68
        /// A voice speaking less than this in total is minor… (no AMI participant speaks
        /// under 8 s, so the bench cannot calibrate this rule; as FLU-22 set it)
        public var minorSeconds: TimeInterval = 8
        /// …or less than this share of all remote speech, in a short meeting.
        public var minorShare: Double = 0.03

        public init() {}
    }

    public struct Result: Sendable, Equatable {
        /// Every input voice → the voice it now belongs to (itself when kept).
        public var mapping: [String: String]
        public var turns: [SpeakerTurn]
        public var embeddings: [String: [Float]]
    }

    /// - Parameters:
    ///   - cap: how many remote voices there can be at most (`speakerCap`), nil when unknown.
    public static func consolidate(
        turns: [SpeakerTurn],
        embeddings: [String: [Float]],
        cap: Int?,
        settings: Settings = Settings()
    ) -> Result {
        var speech: [String: TimeInterval] = [:]
        var order: [String] = []
        for turn in turns {
            if speech[turn.speaker] == nil { order.append(turn.speaker) }
            speech[turn.speaker, default: 0] += max(0, turn.end - turn.start)
        }
        var vectors = embeddings.filter { speech[$0.key] != nil }
        var mapping = Dictionary(uniqueKeysWithValues: order.map { ($0, $0) })
        var alive = order

        func merge(_ small: String, into big: String) {
            if let a = vectors[big], let b = vectors[small], a.count == b.count {
                let wa = Float(speech[big] ?? 0), wb = Float(speech[small] ?? 0)
                let total = max(wa + wb, .leastNonzeroMagnitude)
                vectors[big] = zip(a, b).map { ($0 * wa + $1 * wb) / total }
            } else if vectors[big] == nil {
                vectors[big] = vectors[small]
            }
            speech[big, default: 0] += speech[small] ?? 0
            vectors[small] = nil
            speech[small] = nil
            alive.removeAll { $0 == small }
            for (key, value) in mapping where value == small { mapping[key] = big }
        }

        /// Larger voice first; on a tie, the one heard first.
        func ordered(_ a: String, _ b: String) -> (big: String, small: String) {
            let sa = speech[a] ?? 0, sb = speech[b] ?? 0
            if sa != sb { return sa > sb ? (a, b) : (b, a) }
            return (order.firstIndex(of: a)! < order.firstIndex(of: b)!) ? (a, b) : (b, a)
        }

        func closestPair(minimum: Double?) -> (String, String)? {
            var best: (String, String, Double)?
            for i in alive.indices {
                for j in alive.indices where j > i {
                    guard let a = vectors[alive[i]], let b = vectors[alive[j]],
                          let similarity = cosine(a, b) else { continue }
                    if let minimum, similarity < minimum { continue }
                    if best == nil || similarity > best!.2 { best = (alive[i], alive[j], similarity) }
                }
            }
            return best.map { ($0.0, $0.1) }
        }

        // 1. Near-duplicates.
        while let (a, b) = closestPair(minimum: settings.mergeSimilarity) {
            let pair = ordered(a, b)
            merge(pair.small, into: pair.big)
        }

        // 2. Minor voices, smallest first, while another voice remains to take them.
        let total = speech.values.reduce(0, +)
        let floor = min(settings.minorSeconds, total * settings.minorShare)
        while alive.count > 1,
              let minor = alive.filter({ (speech[$0] ?? 0) < floor })
                  .min(by: { (speech[$0] ?? 0, order.firstIndex(of: $0)!) < (speech[$1] ?? 0, order.firstIndex(of: $1)!) }) {
            let majors = alive.filter { $0 != minor && (speech[$0] ?? 0) >= floor }
            let candidates = majors.isEmpty ? alive.filter { $0 != minor } : majors
            let target = closest(to: minor, among: candidates, vectors: vectors)
                ?? neighbour(of: minor, among: candidates, turns: turns, mapping: mapping)
                ?? candidates[0]
            merge(minor, into: target)
        }

        // 3. The cap.
        if let cap, cap >= 1 {
            while alive.count > cap {
                if let (a, b) = closestPair(minimum: nil) {
                    let pair = ordered(a, b)
                    merge(pair.small, into: pair.big)
                } else {
                    // No embeddings to compare: the smallest voice joins its neighbour.
                    let smallest = alive.min { (speech[$0] ?? 0) < (speech[$1] ?? 0) }!
                    let others = alive.filter { $0 != smallest }
                    merge(smallest, into: neighbour(of: smallest, among: others, turns: turns, mapping: mapping) ?? others[0])
                }
            }
        }

        let newTurns = turns.map { SpeakerTurn(speaker: mapping[$0.speaker] ?? $0.speaker, start: $0.start, end: $0.end) }
        return Result(mapping: mapping, turns: newTurns, embeddings: vectors)
    }

    /// The most remote voices there can be: the larger of the names the call window showed
    /// and the calendar's invitees (both without the user), plus one for an uninvited
    /// guest when only the calendar is known. Nil when neither is known.
    public static func speakerCap(windowParticipants: Int, attendees: Int) -> Int? {
        if windowParticipants > 0 { return max(windowParticipants, attendees) }
        if attendees > 0 { return attendees + 1 }
        return nil
    }

    /// The cap from the call window and the calendar (FLU-33): the window's names count only
    /// when its list looks complete (`ParticipantRoster.trustedCount`). A partial list gives
    /// no cap, so it can never fold distinct voices into the few names it shows.
    public static func speakerCap(roster: ParticipantRoster, attendees: Int) -> Int? {
        speakerCap(windowParticipants: roster.trustedCount ?? 0, attendees: attendees)
    }

    /// The most voices the diarizer may cluster into (FLU-33): the cap, never below two.
    /// The consolidation, which compares the voices' embeddings, makes any last merge.
    public static func diarizerCeiling(cap: Int?) -> Int? {
        cap.map { max($0, 2) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for (x, y) in zip(a, b) {
            dot += Double(x) * Double(y)
            na += Double(x) * Double(x)
            nb += Double(y) * Double(y)
        }
        guard na > 0, nb > 0 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private static func closest(to id: String, among candidates: [String], vectors: [String: [Float]]) -> String? {
        guard let own = vectors[id] else { return nil }
        return candidates
            .compactMap { candidate in vectors[candidate].flatMap { cosine(own, $0) }.map { (candidate, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// The voice speaking closest in time to this one's turns.
    private static func neighbour(of id: String, among candidates: [String], turns: [SpeakerTurn], mapping: [String: String]) -> String? {
        let own = turns.filter { mapping[$0.speaker] == id }
        var best: (String, TimeInterval)?
        for turn in turns {
            guard let owner = mapping[turn.speaker], candidates.contains(owner) else { continue }
            for mine in own {
                let gap = max(0, max(turn.start - mine.end, mine.start - turn.end))
                if best == nil || gap < best!.1 { best = (owner, gap) }
            }
        }
        return best?.0
    }
}
