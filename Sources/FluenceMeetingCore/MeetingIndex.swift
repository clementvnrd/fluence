import Foundation

/// The meetings list, and when it may be written back to `index.enc` (FLU-27).
///
/// Each meeting lives in its own folder; the index only caches their summaries so the list
/// shows without decrypting every meeting. The folders are the truth: the list is rebuilt
/// from them wherever the index lacks a meeting, and the index is written only while it
/// lists every meeting on disk.
///
/// Before, an index that failed to read (the Keychain locked at launch) left the list
/// empty; the next save wrote an index holding only the new meeting, and every earlier
/// meeting vanished from the app while its files stayed on disk, out of reach of « Supprimer
/// toutes les réunions » and of the retention setting.
public struct MeetingIndex: Equatable, Sendable {
    /// Newest first.
    public private(set) var summaries: [MeetingSummary] = []
    /// Meetings on disk that could not be read (the Keychain locked or denied, a damaged
    /// file). They are kept, and they keep the index from being written.
    public private(set) var unreadable: Set<UUID> = []
    /// The folder listing failed: nothing on disk was checked.
    public private(set) var foldersUnknown = false
    /// The index on disk does not list exactly the meetings found: it was missing,
    /// damaged, or out of date. Written again once complete.
    public private(set) var isStale = false

    public init() {}

    /// - Parameters:
    ///   - index: the summaries read from `index.enc`; nil when it is missing or unreadable.
    ///   - folders: the meetings on disk (folders holding a meeting file); nil when the
    ///     meetings folder could not be listed.
    ///   - rebuild: reads one meeting's summary from its folder; nil when it cannot.
    public init(index: [MeetingSummary]?, folders: [UUID]?, rebuild: (UUID) -> MeetingSummary?) {
        guard let folders else {
            summaries = Self.newestFirst(index ?? [])
            foldersUnknown = true
            return
        }
        let indexed = Dictionary((index ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var listed: [MeetingSummary] = []
        for id in Set(folders) {
            if let summary = indexed[id] ?? rebuild(id) {
                listed.append(summary)
            } else {
                unreadable.insert(id)
            }
        }
        summaries = Self.newestFirst(listed)
        isStale = Set(indexed.keys) != Set(listed.map(\.id))
    }

    /// Whether the list holds every meeting on disk. Only then may the index be written.
    public var isComplete: Bool { unreadable.isEmpty && !foldersUnknown }

    /// What to write to `index.enc`, or nil while a meeting on disk is missing from the list.
    public var indexToWrite: [MeetingSummary]? { isComplete ? summaries : nil }

    /// Every meeting known, listed or unreadable.
    public var ids: Set<UUID> { unreadable.union(summaries.map(\.id)) }

    public mutating func saved(_ summary: MeetingSummary) {
        summaries.removeAll { $0.id == summary.id }
        unreadable.remove(summary.id)
        summaries = Self.newestFirst(summaries + [summary])
    }

    public mutating func deleted(_ id: UUID) {
        summaries.removeAll { $0.id == id }
        unreadable.remove(id)
    }

    /// The meetings a retention of `cutoff` deletes: listed ones by their start, unreadable
    /// ones by the day their folder was created (never later than their start, except for an
    /// imported meeting, which then goes later rather than sooner).
    public func expired(before cutoff: Date, folderDates: [UUID: Date]) -> [UUID] {
        summaries.filter { $0.startedAt < cutoff }.map(\.id)
            + unreadable.filter { folderDates[$0].map { $0 < cutoff } ?? false }.sorted { $0.uuidString < $1.uuidString }
    }

    /// The meeting folders among the names in the meetings folder: those named by a UUID.
    public static func meetingIDs(in names: [String]) -> [UUID] {
        names.compactMap(UUID.init(uuidString:))
    }

    private static func newestFirst(_ summaries: [MeetingSummary]) -> [MeetingSummary] {
        summaries.sorted { $0.startedAt > $1.startedAt }
    }
}
