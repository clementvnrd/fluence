import Foundation
import Testing

@testable import FluenceMeetingCore

/// The meetings list rebuilt from the meeting folders, and the index written only when it
/// lists all of them (FLU-27).
struct MeetingIndexTests {
    static let day: TimeInterval = 86_400
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func summary(_ title: String, daysAgo: Double) -> MeetingSummary {
        MeetingSummary(Meeting(title: title, startedAt: now.addingTimeInterval(-daysAgo * day)))
    }

    let monday = Self.summary("Lundi", daysAgo: 3)
    let tuesday = Self.summary("Mardi", daysAgo: 2)
    let today = Self.summary("Aujourd'hui", daysAgo: 0)

    @Test("the Keychain locked at launch, then a meeting saved: the index is not overwritten")
    func lockedKeychainKeepsTheIndex() {
        // Launch: the index cannot be read and neither can the meetings (same master key).
        var index = MeetingIndex(index: nil, folders: [monday.id, tuesday.id], rebuild: { _ in nil })
        #expect(index.summaries.isEmpty)
        #expect(index.unreadable == [monday.id, tuesday.id])

        // A new meeting is saved. Writing the index now would leave only this one listed.
        index.saved(today)
        #expect(index.indexToWrite == nil)
        #expect(index.ids == [monday.id, tuesday.id, today.id])

        // Next launch, the Keychain open: every meeting is back, and the index is rewritten.
        let known = [monday, tuesday, today]
        let reopened = MeetingIndex(index: [today], folders: known.map(\.id)) { id in known.first { $0.id == id } }
        #expect(reopened.indexToWrite == [today, tuesday, monday])
        #expect(reopened.isStale)
    }

    @Test("a damaged index is rebuilt from the folders")
    func damagedIndexIsRebuilt() {
        let known = [monday, tuesday]
        let index = MeetingIndex(index: nil, folders: known.map(\.id)) { id in known.first { $0.id == id } }
        #expect(index.summaries == [tuesday, monday])
        #expect(index.isComplete)
        #expect(index.isStale)
    }

    @Test("a sound index is used as it is, without decrypting the meetings")
    func soundIndexIsTrusted() {
        let index = MeetingIndex(index: [monday, tuesday], folders: [monday.id, tuesday.id]) { _ in
            Issue.record("rebuilt a meeting the index already lists")
            return nil
        }
        #expect(index.summaries == [tuesday, monday])
        #expect(!index.isStale)
    }

    @Test("an index entry whose folder is gone is dropped")
    func entryWithoutFolderIsDropped() {
        let index = MeetingIndex(index: [monday, tuesday], folders: [tuesday.id], rebuild: { _ in nil })
        #expect(index.summaries == [tuesday])
        #expect(index.isStale)
        #expect(index.indexToWrite == [tuesday])
    }

    @Test("a meetings folder that cannot be listed keeps the index and never writes it")
    func unlistedFolderWritesNothing() {
        let index = MeetingIndex(index: [monday], folders: nil, rebuild: { _ in nil })
        #expect(index.summaries == [monday])
        #expect(index.indexToWrite == nil)
    }

    @Test("retention reaches unreadable meetings by their folder's date")
    func retentionReachesUnreadable() {
        let old = UUID()
        let recent = UUID()
        let index = MeetingIndex(index: [monday, today], folders: [monday.id, today.id, old, recent], rebuild: { _ in nil })
        let cutoff = Self.now.addingTimeInterval(-1 * Self.day)
        let expired = index.expired(before: cutoff, folderDates: [
            old: Self.now.addingTimeInterval(-40 * Self.day),
            recent: Self.now,
        ])
        #expect(Set(expired) == [monday.id, old])
    }

    @Test("deleting an unreadable meeting lets the index be written again")
    func deletingUnreadableCompletes() {
        let lost = UUID()
        var index = MeetingIndex(index: [monday], folders: [monday.id, lost], rebuild: { _ in nil })
        #expect(index.indexToWrite == nil)
        index.deleted(lost)
        #expect(index.indexToWrite == [monday])
    }

    @Test("only folders named by a UUID are meetings")
    func folderNames() {
        let id = UUID()
        #expect(MeetingIndex.meetingIDs(in: [id.uuidString, "index.enc", ".DS_Store", "notes"]) == [id])
    }
}
