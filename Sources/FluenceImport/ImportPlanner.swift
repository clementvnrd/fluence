import FluenceCore
import FluenceDictionary
import FluenceMeetingCore
import Foundation

/// Where each app keeps its data, under a home folder (FLU-144).
public struct ImportLocations: Sendable {
    public var home: URL

    public init(home: URL) {
        self.home = home
    }

    var wisprDatabase: URL { home.appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite") }
    var wisprMeetings: URL { home.appendingPathComponent("Library/Application Support/Wispr Flow/meetings", isDirectory: true) }
    var superwhisperSettings: URL { home.appendingPathComponent("superwhisper/settings/settings.json") }
    var granolaCache: URL { home.appendingPathComponent("Library/Application Support/Granola/cache-v3.json") }

    /// `~/Documents/superwhisper` sits behind a privacy prompt: looked at on a click only.
    func superwhisperRecordings(includeDocuments: Bool) -> [URL] {
        ["superwhisper/recordings"].map { home.appendingPathComponent($0, isDirectory: true) }
            + (includeDocuments ? [home.appendingPathComponent("Documents/superwhisper/recordings", isDirectory: true)] : [])
    }

    public func isFound(_ app: ImportApp, includeDocuments: Bool) -> Bool {
        let files: [URL] = switch app {
        case .wisprFlow: [wisprDatabase]
        case .superwhisper: [superwhisperSettings] + superwhisperRecordings(includeDocuments: includeDocuments)
        case .granola: [granolaCache]
        }
        return files.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// One app after the scan: not found, read, or found but unreadable.
public struct ImportScan: Sendable {
    public var app: ImportApp
    public var isFound: Bool
    public var data: ForeignData?

    public init(app: ImportApp, isFound: Bool, data: ForeignData?) {
        self.app = app
        self.isFound = isFound
        self.data = data
    }
}

public enum ImportScanner {
    /// Reads every app found, in `ImportApp` order. Slow on a large history: call it off the
    /// main actor.
    public static func scan(_ locations: ImportLocations, includeDocuments: Bool) -> [ImportScan] {
        ImportApp.allCases.map { app in
            guard locations.isFound(app, includeDocuments: includeDocuments) else {
                return ImportScan(app: app, isFound: false, data: nil)
            }
            let data: ForeignData? = switch app {
            case .wisprFlow:
                try? WisprFlowSource.read(database: locations.wisprDatabase, meetingsFolder: locations.wisprMeetings)
            case .superwhisper:
                SuperwhisperSource.read(
                    settings: locations.superwhisperSettings,
                    recordingsFolders: locations.superwhisperRecordings(includeDocuments: includeDocuments)
                )
            case .granola:
                (try? Data(contentsOf: locations.granolaCache)).flatMap { try? GranolaSource.read($0) }
            }
            return ImportScan(app: app, isFound: true, data: data)
        }
    }
}

/// What Fluence already holds, to leave out what a previous import (or the user) already added.
public struct ImportExisting: Sendable {
    public var entries: [DictionaryEntry]
    public var snippets: [Snippet]
    public var dictations: [(id: UUID, date: Date)]
    public var meetings: [(id: UUID, title: String, startedAt: Date)]

    public init(
        entries: [DictionaryEntry] = [], snippets: [Snippet] = [],
        dictations: [(id: UUID, date: Date)] = [], meetings: [(id: UUID, title: String, startedAt: Date)] = []
    ) {
        self.entries = entries
        self.snippets = snippets
        self.dictations = dictations
        self.meetings = meetings
    }
}

/// The counts behind one checkbox.
public struct ImportTally: Equatable, Sendable {
    /// New items, imported if the box is ticked.
    public var toImport = 0
    /// Of `toImport`, the meetings that are notes.
    public var notes = 0
    /// Dictations older than the history keeps.
    public var leftAside = 0
    /// Already in Fluence, or already given by an app read before.
    public var duplicates = 0

    public init(toImport: Int = 0, notes: Int = 0, leftAside: Int = 0, duplicates: Int = 0) {
        self.toImport = toImport
        self.notes = notes
        self.leftAside = leftAside
        self.duplicates = duplicates
    }
}

public struct PlannedDictation: Sendable {
    public var app: ImportApp
    public var dictation: ForeignDictation
}

/// What an import adds, and the counts the screen shows.
public struct ImportPlan: Sendable {
    public var tallies: [ImportChoice: ImportTally] = [:]
    public var entries: [DictionaryEntry] = []
    public var snippets: [Snippet] = []
    public var dictations: [PlannedDictation] = []
    public var meetings: [Meeting] = []

    public init() {}

    public func tally(_ app: ImportApp, _ kind: ImportKind) -> ImportTally {
        tallies[ImportChoice(app, kind)] ?? ImportTally()
    }

    public var isEmpty: Bool { entries.isEmpty && snippets.isEmpty && dictations.isEmpty && meetings.isEmpty }
}

public enum ImportPlanner {
    /// Two dictations this close are one utterance (superwhisper's copy of a Wispr Flow one is
    /// stamped the same second).
    static let sameDictation: Int = 1
    /// Two meetings with one title this close are one meeting (Wispr Flow imports Granola's).
    static let sameMeeting: TimeInterval = 120

    /// With « Ne pas garder », dictations are not offered at all.
    public static func offersDictations(_ retention: HistoryRetention) -> Bool { retention.persists }

    /// Tallies every checkbox, ticked or not; collects only the ticked ones. An app read later
    /// loses what an earlier, ticked one already gives, and nothing Fluence holds is added again.
    public static func plan(
        _ sources: [ForeignData],
        selection: Set<ImportChoice>,
        retention: HistoryRetention,
        now: Date,
        existing: ImportExisting,
        userNames: [String]
    ) -> ImportPlan {
        var plan = ImportPlan()
        var entryKeys = Set(existing.entries.map(\.mergeKey))
        var snippetIDs = Set(existing.snippets.map(\.id))
        var triggers = Set(existing.snippets.map { triggerKey($0.trigger) })
        var dictationIDs = Set(existing.dictations.map(\.id))
        var seconds = Set(existing.dictations.map { second($0.date) })
        var meetingIDs = Set(existing.meetings.map(\.id))
        var meetingKeys = existing.meetings.map { (titleKey($0.title), $0.startedAt) }
        let cutoff = retention.cutoff(now: now)

        for source in sources {
            let app = source.app

            // Dictionary and snippets.
            var tally = ImportTally()
            var keys = Set<String>(), ids = Set<UUID>(), words = Set<String>()
            var entries: [DictionaryEntry] = [], snippets: [Snippet] = []
            for entry in source.entries where DictionaryFileFormat.canStore(entry) {
                if entryKeys.contains(entry.mergeKey) || !keys.insert(entry.mergeKey).inserted {
                    tally.duplicates += 1
                } else {
                    entries.append(entry)
                }
            }
            for snippet in source.snippets {
                let key = triggerKey(snippet.trigger)
                if snippetIDs.contains(snippet.id) || triggers.contains(key) || ids.contains(snippet.id) || !words.insert(key).inserted {
                    tally.duplicates += 1
                } else {
                    ids.insert(snippet.id)
                    snippets.append(snippet)
                }
            }
            tally.toImport = entries.count + snippets.count
            plan.tallies[ImportChoice(app, .dictionary)] = tally
            if selection.contains(ImportChoice(app, .dictionary)) {
                entryKeys.formUnion(keys)
                snippetIDs.formUnion(ids)
                triggers.formUnion(words)
                plan.entries += entries
                plan.snippets += snippets
            }

            // Dictations: duplicates first, so a copy is not also counted as left aside.
            if offersDictations(retention) {
                tally = ImportTally()
                var stamps = Set<Int>()
                var planned: [PlannedDictation] = []
                for dictation in source.dictations {
                    let stamp = second(dictation.date)
                    if dictationIDs.contains(dictation.id)
                        || (stamp - sameDictation...stamp + sameDictation).contains(where: seconds.contains) {
                        tally.duplicates += 1
                        continue
                    }
                    stamps.insert(stamp)
                    if let cutoff, dictation.date < cutoff {
                        tally.leftAside += 1
                    } else {
                        planned.append(PlannedDictation(app: app, dictation: dictation))
                    }
                }
                tally.toImport = planned.count
                plan.tallies[ImportChoice(app, .dictations)] = tally
                if selection.contains(ImportChoice(app, .dictations)) {
                    seconds.formUnion(stamps)
                    dictationIDs.formUnion(source.dictations.map(\.id))
                    plan.dictations += planned
                }
            }

            // Meetings and notes.
            tally = ImportTally()
            var meetings: [Meeting] = []
            var added: [(String, Date)] = []
            for foreign in source.meetings {
                let key = titleKey(foreign.title)
                if meetingIDs.contains(foreign.id)
                    || (!key.isEmpty && meetingKeys.contains { $0.0 == key && abs($0.1.timeIntervalSince(foreign.startedAt)) <= sameMeeting }) {
                    tally.duplicates += 1
                    continue
                }
                added.append((key, foreign.startedAt))
                if foreign.isNote { tally.notes += 1 }
                meetings.append(meeting(foreign, app: app, userNames: userNames))
            }
            tally.toImport = meetings.count
            plan.tallies[ImportChoice(app, .meetings)] = tally
            if selection.contains(ImportChoice(app, .meetings)) {
                meetingIDs.formUnion(meetings.map(\.id))
                meetingKeys += added
                plan.meetings += meetings
            }
        }
        return plan
    }

    /// A Fluence meeting, through the transcript import FLU-16 uses: imported, retention
    /// counted from now, the other app named as its source.
    static func meeting(_ foreign: ForeignMeeting, app: ImportApp, userNames: [String]) -> Meeting {
        let speakers = foreign.transcript.speakers
        let me = speakers.contains(Placeholder.me)
            ? Placeholder.me
            : TranscriptImport.guessMe(in: speakers.filter { !$0.hasPrefix(Placeholder.prefix) }, userNames: userNames)
        var meeting = TranscriptImport.meeting(
            from: foreign.transcript,
            title: foreign.title.isEmpty ? (foreign.isNote ? "Note importée" : "Réunion importée") : foreign.title,
            startedAt: foreign.startedAt,
            me: me,
            sourceName: app.name
        )
        meeting.id = foreign.id
        if let end = foreign.endedAt, end > meeting.endedAt ?? foreign.startedAt { meeting.endedAt = end }
        meeting.userNotes = foreign.userNotes
        meeting.notes = foreign.summary.map {
            MeetingNotes(recap: $0, nextSteps: [], decisions: [], openQuestions: [], generatedAt: meeting.endedAt ?? foreign.startedAt, model: app.name)
        }
        for index in meeting.speakers.indices where meeting.speakers[index].name?.hasPrefix(Placeholder.prefix) == true {
            meeting.speakers[index].name = nil
            meeting.speakers[index].nameSource = nil
        }
        return meeting
    }

    private static func second(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded(.down)) }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func triggerKey(_ trigger: String) -> String { fold(trigger) }
    private static func titleKey(_ title: String) -> String { fold(title) }
}
