import CryptoKit
import Foundation
import Observation

/// Encrypted on-disk store for meetings.
///
/// Layout, under `Application Support/Fluence/Meetings/`:
///
/// ```
/// index.enc                 [MeetingSummary], sealed with the master key
/// <uuid>/key.wrapped        the meeting's own AES-256 key, wrapped by the master key
/// <uuid>/meeting.enc        the Meeting, sealed with the meeting key
/// <uuid>/audio-*.enc        spooled audio (see MeetingAudioSpool), deleted after processing
///                           unless the user kept it
/// ```
///
/// Deleting a meeting removes its directory, wrapped key included — any fragment of its
/// files left on the SSD becomes unreadable.
///
/// The folders are the truth and the index a cache of their summaries: the list is rebuilt
/// from the folders wherever the index lacks a meeting, and the index is written only while
/// it lists every meeting on disk (`MeetingIndex`, FLU-27).
@MainActor
@Observable
final class MeetingStore {
    static let shared = MeetingStore()

    private var index = MeetingIndex()
    /// Newest first.
    var summaries: [MeetingSummary] { index.summaries }
    /// Every meeting on disk, the unreadable ones included.
    var meetingIDs: Set<UUID> { index.ids }
    /// Set when the store could not be read (Keychain locked or denied). Shown in the UI —
    /// the store never falls back to writing plaintext.
    private(set) var lastError: String?

    let root: URL

    init(root: URL = AppPaths.directory("Meetings")) {
        self.root = root
        AppPaths.protect(root)
        loadIndex()
    }

    // MARK: - Reading

    func load(_ id: UUID) throws -> Meeting {
        let key = try meetingKey(for: id, create: false)
        let data = try Vault.read(directory(for: id).appendingPathComponent("meeting.enc"), with: key)
        return try Self.decoder.decode(Meeting.self, from: data)
    }

    /// Case- and diacritic-insensitive search over titles, speakers, notes and transcripts.
    /// Decrypts each meeting in turn: fine for hundreds of meetings, and nothing searchable
    /// is ever kept in plaintext.
    func search(_ query: String) -> [MeetingSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return summaries }
        return summaries.filter { summary in
            if Self.matches(summary.title, needle) { return true }
            if summary.speakerNames.contains(where: { Self.matches($0, needle) }) { return true }
            guard let meeting = try? load(summary.id) else { return false }
            return Self.matches(meeting.transcriptText, needle)
                || Self.matches(meeting.userNotes, needle)
                || Self.matches(meeting.notes?.recap ?? "", needle)
        }
    }

    private static func matches(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: - Writing

    func save(_ meeting: Meeting) throws {
        let key = try meetingKey(for: meeting.id, create: true)
        let data = try Self.encoder.encode(meeting)
        try Vault.write(data, to: directory(for: meeting.id).appendingPathComponent("meeting.enc"), with: key)

        // The Keychain may have opened since launch: read the meetings that were not.
        if !index.isComplete { loadIndex() }
        index.saved(MeetingSummary(meeting))
        try saveIndex()
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        index.deleted(id)
        try? saveIndex()
    }

    /// Every meeting folder on disk — listed or not, readable or not — with its spooled audio,
    /// and the index.
    func deleteAll() {
        for id in MeetingIndex.meetingIDs(in: folderNames() ?? []) {
            try? FileManager.default.removeItem(at: directory(for: id))
        }
        index = MeetingIndex()
        lastError = nil
        try? FileManager.default.removeItem(at: indexURL)
    }

    /// Deletes meetings older than `days`, the unreadable ones by their folder's date.
    /// `nil` keeps everything.
    func purge(olderThan days: Int?) {
        guard let days else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var folderDates: [UUID: Date] = [:]
        for id in index.unreadable {
            folderDates[id] = try? directory(for: id).resourceValues(forKeys: [.creationDateKey]).creationDate
        }
        for id in index.expired(before: cutoff, folderDates: folderDates) {
            delete(id)
        }
    }

    // MARK: - Keys and paths

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The meeting's data key. The audio spool uses the same key, so deleting the meeting
    /// directory makes its audio unreadable too.
    func meetingKey(for id: UUID, create: Bool) throws -> SymmetricKey {
        let directory = directory(for: id)
        let url = directory.appendingPathComponent("key.wrapped")
        if let wrapped = try? Data(contentsOf: url) {
            return try Vault.unwrap(wrapped)
        }
        guard create else { throw Vault.Failure.corrupt }
        AppPaths.protect(directory)
        let key = Vault.newDataKey()
        try Vault.wrap(key).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return key
    }

    // MARK: - Index

    private var indexURL: URL { root.appendingPathComponent("index.enc") }

    /// Reads the index, checks it against the meeting folders, and decrypts only the meetings
    /// it lacks. A stale index is rewritten once every meeting could be read.
    private func loadIndex() {
        var saved: [MeetingSummary]?
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                saved = try Self.decoder.decode([MeetingSummary].self, from: Vault.read(indexURL))
            } catch {
                Log.app.error("meeting index unreadable, rebuilding from the folders: \(String(describing: error), privacy: .public)")
            }
        }
        let folders = folderNames().map { names in
            MeetingIndex.meetingIDs(in: names).filter {
                FileManager.default.fileExists(atPath: directory(for: $0).appendingPathComponent("meeting.enc").path)
            }
        }
        index = MeetingIndex(index: saved, folders: folders) { id in
            (try? load(id)).map { MeetingSummary($0) }
        }

        switch index.unreadable.count {
        case 0: lastError = nil
        case 1: lastError = "Une réunion n'a pas pu être déchiffrée. Elle est conservée, rien n'est effacé."
        case let count: lastError = "\(count) réunions n'ont pas pu être déchiffrées. Elles sont conservées, rien n'est effacé."
        }
        if !index.unreadable.isEmpty {
            Log.app.error("\(self.index.unreadable.count) meetings unreadable; the index is left as it is")
        }
        if index.isStale { try? saveIndex() }
    }

    /// Writes nothing while a meeting on disk is missing from the list: an index written
    /// then would hide it for good.
    private func saveIndex() throws {
        guard let summaries = index.indexToWrite else {
            Log.app.info("meeting index not written: \(self.index.unreadable.count) meetings unreadable")
            return
        }
        try Vault.write(Self.encoder.encode(summaries), to: indexURL)
    }

    /// The names in the meetings folder; nil when it cannot be listed.
    private func folderNames() -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: root.path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
