import Foundation

/// Puts names on the remote voices `S1…Sn` after diarization, most trusted source first
/// (docs/NOTETAKER.md §2.5):
///
/// 1. **Meeting window** — display names read from Zoom / Teams / Meet. Only applied when
///    it cannot be wrong about *who is who*: exactly one remote voice and exactly one
///    remote participant.
/// 2. **Voice prints** (opt-in) — Hungarian assignment on cosine similarity, restricted by
///    the caller to the allowed names (calendar attendees). Pairs below
///    `minimumSimilarity` are left unnamed.
/// 3. **Elimination** — when exactly one voice is still unnamed and exactly one candidate
///    is still unused: first among the window participants (only when the window lists as
///    many remote people as there are voices), then among the calendar attendees.
///
/// A speaker whose name came from the user (`.user`) is never touched, and their name is
/// never handed to another voice. Names are compared case- and diacritic-insensitively.
public enum SpeakerNaming {
    public static let minimumSimilarity = 0.55

    public struct Candidates: Sendable {
        /// Remote display names read from the meeting window, the user excluded.
        public var windowParticipants: [String]
        /// Calendar attendees, the user excluded.
        public var attendees: [String]
        /// Speaker id → candidate name → cosine similarity of the voice to the enrolled
        /// print. Already restricted to the names the caller allows.
        public var voicePrintSimilarity: [String: [String: Double]]

        public init(
            windowParticipants: [String] = [],
            attendees: [String] = [],
            voicePrintSimilarity: [String: [String: Double]] = [:]
        ) {
            self.windowParticipants = windowParticipants
            self.attendees = attendees
            self.voicePrintSimilarity = voicePrintSimilarity
        }
    }

    /// Returns `speakers` with names filled in where the evidence allows. `me` and
    /// already-named speakers are returned unchanged.
    public static func name(_ speakers: [Speaker], candidates: Candidates) -> [Speaker] {
        var result = speakers
        let remote = result.indices.filter { !result[$0].isMe && result[$0].id != Speaker.othersID }

        var taken = Set(result.compactMap { speaker in speaker.name.map(key) })
        func isUnnamed(_ index: Int) -> Bool { (result[index].name ?? "").isEmpty }
        func give(_ name: String, to index: Int, source: NameSource) {
            result[index].name = name
            result[index].nameSource = source
            taken.insert(key(name))
        }

        let window = unique(candidates.windowParticipants)
        let attendees = unique(candidates.attendees)

        // 1. Meeting window: one voice, one participant.
        if remote.count == 1, window.count == 1, isUnnamed(remote[0]), !taken.contains(key(window[0])) {
            give(window[0], to: remote[0], source: .meetingWindow)
        }

        // 2. Voice prints.
        let unnamed = remote.filter(isUnnamed)
        let printNames = unique(candidates.voicePrintSimilarity.values.flatMap(\.keys).sorted())
            .filter { !taken.contains(key($0)) }
        if !unnamed.isEmpty, !printNames.isEmpty {
            let similarity = unnamed.map { index in
                printNames.map { candidates.voicePrintSimilarity[result[index].id]?[$0] ?? -1 }
            }
            let assignment = Hungarian.assign(similarity.map { $0.map { 1 - $0 } })
            for (row, column) in assignment.enumerated() {
                guard let column, similarity[row][column] >= minimumSimilarity else { continue }
                give(printNames[column], to: unnamed[row], source: .voicePrint)
            }
        }

        // 3. Elimination.
        let stillUnnamed = remote.filter(isUnnamed)
        if stillUnnamed.count == 1 {
            let unusedWindow = window.filter { !taken.contains(key($0)) }
            let unusedAttendees = attendees.filter { !taken.contains(key($0)) }
            if window.count == remote.count, unusedWindow.count == 1 {
                give(unusedWindow[0], to: stillUnnamed[0], source: .meetingWindow)
            } else if unusedAttendees.count == 1 {
                give(unusedAttendees[0], to: stillUnnamed[0], source: .calendar)
            }
        }

        return result
    }

    /// Cosine similarity of two embeddings; 0 when either is empty, zero or the lengths
    /// differ.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            let (x, y) = (Double(a[i]), Double(b[i]))
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(key(trimmed)).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
