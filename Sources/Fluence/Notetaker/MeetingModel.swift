import Foundation

// The Notetaker's data model. Everything here is plain `Codable` data: the capture and
// transcription pipeline produces it, the store encrypts it, the notes and the UI read it.
// Design: docs/NOTETAKER.md.

/// Which physical stream a piece of speech came from. The mic is the user; the system
/// stream is everyone else. That split is the backbone of speaker attribution — only the
/// system stream is ever diarized.
enum AudioSource: String, Codable, Sendable, CaseIterable {
    case microphone
    case system
}

/// Where a speaker's name came from, most trusted first. Shown in the UI so the user can
/// tell a name they typed from one the app inferred.
enum NameSource: String, Codable, Sendable {
    /// Typed or confirmed by the user. Never overwritten by an inference.
    case user
    /// Read from the meeting app's window (Zoom, Teams, Meet display names).
    case meetingWindow
    /// Matched against an enrolled voice print (opt-in).
    case voicePrint
    /// The only remaining calendar attendee, by elimination.
    case calendar
}

struct Speaker: Codable, Sendable, Identifiable, Hashable {
    /// Stable within one meeting: `"me"` for the user, `"S1"`, `"S2"`… for remote voices.
    let id: String
    var name: String?
    var nameSource: NameSource?
    var isMe: Bool { id == Speaker.meID }

    static let meID = "me"
    static func me(named name: String? = nil) -> Speaker {
        Speaker(id: meID, name: name, nameSource: name == nil ? nil : .user)
    }

    /// What the UI prints: the name if known, otherwise "You" / "Speaker 2".
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if isMe { return "You" }
        return "Speaker " + id.dropFirst()
    }
}

/// One recognised word, timed relative to the meeting start.
struct Word: Codable, Sendable, Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Float?
}

/// One utterance from one source, attributed to one speaker.
struct TranscriptSegment: Codable, Sendable, Identifiable, Hashable {
    var id = UUID()
    var source: AudioSource
    var speakerID: String
    /// Seconds from the meeting start.
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var words: [Word] = []
    /// False while the live pass may still revise it; the final pass sets it true.
    var isFinal: Bool = false
}

struct ActionItem: Codable, Sendable, Hashable {
    var text: String
    var owner: String?
    var due: String?
}

/// The generated notes. Absent until the summariser has run; never invented when the
/// on-device model is unavailable.
struct MeetingNotes: Codable, Sendable, Hashable {
    var recap: String
    var nextSteps: [ActionItem]
    var decisions: [String]
    var openQuestions: [String]
    var generatedAt: Date
    /// Which model wrote them, e.g. "Apple Foundation Models".
    var model: String
}

/// How the recording was started — kept for the meetings list and for diagnosing
/// detection problems.
enum MeetingTrigger: String, Codable, Sendable {
    case detected
    case manual
    case calendar
}

struct Meeting: Codable, Sendable, Identifiable {
    var id = UUID()
    var title: String
    /// Bundle ID of the meeting app (`us.zoom.xos`, `com.microsoft.teams2`, a browser…).
    var appBundleID: String?
    var trigger: MeetingTrigger = .manual
    var startedAt: Date
    var endedAt: Date?
    /// Calendar attendees (display names), the user excluded. Candidates for naming.
    var attendees: [String] = []
    var speakers: [Speaker] = [.me()]
    /// Time-ordered, both sources merged.
    var segments: [TranscriptSegment] = []
    /// What the user typed during the meeting.
    var userNotes: String = ""
    var notes: MeetingNotes?
    /// Decision FLU-9 #2: audio is deleted after processing unless this is set for the
    /// meeting.
    var keepAudio: Bool = false
    /// BCP-47 code of the dominant language, when known.
    var language: String?

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    func speaker(_ id: String) -> Speaker? {
        speakers.first { $0.id == id }
    }

    /// The full transcript as plain text, one line per segment: `[mm:ss] Name: text`.
    var transcriptText: String {
        segments.map { segment in
            let name = speaker(segment.speakerID)?.displayName ?? segment.speakerID
            return "[\(Self.clock(segment.start))] \(name): \(segment.text)"
        }.joined(separator: "\n")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

/// What the meetings list needs, without decrypting every transcript.
struct MeetingSummary: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var speakerNames: [String]
    var hasNotes: Bool

    init(_ meeting: Meeting) {
        id = meeting.id
        title = meeting.title
        startedAt = meeting.startedAt
        duration = meeting.duration
        speakerNames = meeting.speakers.map(\.displayName)
        hasNotes = meeting.notes != nil
    }
}

extension Notification.Name {
    /// Posted on the main actor once a meeting's final pass (diarization, naming) is saved.
    /// `object` is the meeting's `UUID`. The notes generator listens for it.
    static let meetingFinalized = Notification.Name("FluenceMeetingFinalized")
}
