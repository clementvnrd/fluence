import Foundation

// The Notetaker's data model. Everything here is plain `Codable` data: the capture and
// transcription pipeline produces it, the store encrypts it, the notes and the UI read it.
// Design: docs/NOTETAKER.md.
//
// Lives in FluenceMeetingCore (no AppKit, no AVFoundation) so the merge, dedupe and
// speaker-assignment logic that operates on it can be unit-tested, and so the Windows port
// has one reference for the shapes behind shared/meeting-test-vectors.json. The app target
// re-exports this module, so app code uses these types without importing anything.
//
// The explicit `public init`s mirror what Swift would synthesise inside one module; keep
// their parameter lists in step with the stored properties.

/// Which physical stream a piece of speech came from. The mic is the user; the system
/// stream is everyone else. That split is the backbone of speaker attribution — only the
/// system stream is ever diarized.
public enum AudioSource: String, Codable, Sendable, CaseIterable {
    case microphone
    case system
}

/// Where a speaker's name came from, most trusted first. Shown in the UI so the user can
/// tell a name they typed from one the app inferred.
public enum NameSource: String, Codable, Sendable {
    /// Typed or confirmed by the user. Never overwritten by an inference.
    case user
    /// Read from the meeting app's window (Zoom, Teams, Meet display names).
    case meetingWindow
    /// Matched against an enrolled voice print (opt-in).
    case voicePrint
    /// The only remaining calendar attendee, by elimination.
    case calendar
}

public struct Speaker: Codable, Sendable, Identifiable, Hashable {
    /// Stable within one meeting: `"me"` for the user, `"S1"`, `"S2"`… for remote voices.
    public let id: String
    public var name: String?
    public var nameSource: NameSource?
    public var isMe: Bool { id == Speaker.meID }

    public static let meID = "me"
    /// Remote speech before the final pass has diarized it: everyone on the system stream.
    public static let othersID = "S?"

    public init(id: String, name: String? = nil, nameSource: NameSource? = nil) {
        self.id = id
        self.name = name
        self.nameSource = nameSource
    }

    public static func me(named name: String? = nil) -> Speaker {
        Speaker(id: meID, name: name, nameSource: name == nil ? nil : .user)
    }

    /// The provisional "everyone else" speaker used by the live pass.
    public static let others = Speaker(id: othersID)

    /// What the UI prints: the name if known, otherwise "You" / "Others" / "Speaker 2".
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if isMe { return "You" }
        if id == Speaker.othersID { return "Others" }
        return "Speaker " + id.dropFirst()
    }
}

/// One recognised word, timed relative to the meeting start.
public struct Word: Codable, Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float?

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// One utterance from one source, attributed to one speaker.
public struct TranscriptSegment: Codable, Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var source: AudioSource
    public var speakerID: String
    /// Seconds from the meeting start.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var words: [Word] = []
    /// False while the live pass may still revise it; the final pass sets it true.
    public var isFinal: Bool = false

    public init(
        id: UUID = UUID(),
        source: AudioSource,
        speakerID: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        words: [Word] = [],
        isFinal: Bool = false
    ) {
        self.id = id
        self.source = source
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.isFinal = isFinal
    }
}

public struct ActionItem: Codable, Sendable, Hashable {
    public var text: String
    public var owner: String?
    public var due: String?

    public init(text: String, owner: String? = nil, due: String? = nil) {
        self.text = text
        self.owner = owner
        self.due = due
    }
}

/// The generated notes. Absent until the summariser has run; never invented when the
/// on-device model is unavailable.
public struct MeetingNotes: Codable, Sendable, Hashable {
    public var recap: String
    public var nextSteps: [ActionItem]
    public var decisions: [String]
    public var openQuestions: [String]
    public var generatedAt: Date
    /// Which model wrote them, e.g. "Apple Foundation Models".
    public var model: String

    public init(
        recap: String,
        nextSteps: [ActionItem],
        decisions: [String],
        openQuestions: [String],
        generatedAt: Date,
        model: String
    ) {
        self.recap = recap
        self.nextSteps = nextSteps
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.generatedAt = generatedAt
        self.model = model
    }
}

/// How the recording was started — kept for the meetings list and for diagnosing
/// detection problems.
public enum MeetingTrigger: String, Codable, Sendable {
    case detected
    case manual
    case calendar
}

public struct Meeting: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    /// Bundle ID of the meeting app (`us.zoom.xos`, `com.microsoft.teams2`, a browser…).
    public var appBundleID: String?
    public var trigger: MeetingTrigger = .manual
    public var startedAt: Date
    public var endedAt: Date?
    /// Calendar attendees (display names), the user excluded. Candidates for naming.
    public var attendees: [String] = []
    public var speakers: [Speaker] = [.me()]
    /// Time-ordered, both sources merged.
    public var segments: [TranscriptSegment] = []
    /// What the user typed during the meeting.
    public var userNotes: String = ""
    public var notes: MeetingNotes?
    /// Decision FLU-9 #2: audio is deleted after processing unless this is set for the
    /// meeting.
    public var keepAudio: Bool = false
    /// BCP-47 code of the dominant language, when known.
    public var language: String?

    public init(
        id: UUID = UUID(),
        title: String,
        appBundleID: String? = nil,
        trigger: MeetingTrigger = .manual,
        startedAt: Date,
        endedAt: Date? = nil,
        attendees: [String] = [],
        speakers: [Speaker] = [.me()],
        segments: [TranscriptSegment] = [],
        userNotes: String = "",
        notes: MeetingNotes? = nil,
        keepAudio: Bool = false,
        language: String? = nil
    ) {
        self.id = id
        self.title = title
        self.appBundleID = appBundleID
        self.trigger = trigger
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.attendees = attendees
        self.speakers = speakers
        self.segments = segments
        self.userNotes = userNotes
        self.notes = notes
        self.keepAudio = keepAudio
        self.language = language
    }

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    public func speaker(_ id: String) -> Speaker? {
        speakers.first { $0.id == id }
    }

    /// The full transcript as plain text, one line per segment: `[mm:ss] Name: text`.
    public var transcriptText: String {
        segments.map { segment in
            let name = speaker(segment.speakerID)?.displayName ?? segment.speakerID
            return "[\(Self.clock(segment.start))] \(name): \(segment.text)"
        }.joined(separator: "\n")
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

/// What the meetings list needs, without decrypting every transcript.
public struct MeetingSummary: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var speakerNames: [String]
    public var hasNotes: Bool

    public init(_ meeting: Meeting) {
        id = meeting.id
        title = meeting.title
        startedAt = meeting.startedAt
        duration = meeting.duration
        speakerNames = meeting.speakers.map(\.displayName)
        hasNotes = meeting.notes != nil
    }
}
