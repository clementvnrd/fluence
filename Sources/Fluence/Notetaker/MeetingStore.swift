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
@MainActor
@Observable
final class MeetingStore {
    static let shared = MeetingStore()

    /// Newest first.
    private(set) var summaries: [MeetingSummary] = []
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

        summaries.removeAll { $0.id == meeting.id }
        summaries.append(MeetingSummary(meeting))
        summaries.sort { $0.startedAt > $1.startedAt }
        try saveIndex()
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        summaries.removeAll { $0.id == id }
        try? saveIndex()
    }

    /// Every meeting, every spooled audio file, and the index.
    func deleteAll() {
        for summary in summaries {
            try? FileManager.default.removeItem(at: directory(for: summary.id))
        }
        summaries = []
        try? FileManager.default.removeItem(at: indexURL)
    }

    /// Deletes meetings older than `days`. `nil` keeps everything.
    func purge(olderThan days: Int?) {
        guard let days else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for summary in summaries where summary.startedAt < cutoff {
            delete(summary.id)
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

    private func loadIndex() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            summaries = try Self.decoder.decode([MeetingSummary].self, from: Vault.read(indexURL))
                .sorted { $0.startedAt > $1.startedAt }
            lastError = nil
        } catch {
            lastError = "Les réunions n'ont pas pu être déchiffrées : \(error)"
            Log.app.error("meeting index unreadable: \(String(describing: error), privacy: .public)")
        }
    }

    private func saveIndex() throws {
        try Vault.write(Self.encoder.encode(summaries), to: indexURL)
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
