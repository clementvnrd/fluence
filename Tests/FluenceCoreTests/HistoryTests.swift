import Foundation
import Testing

@testable import FluenceCore

/// A reversible stand-in for AES-GCM: enough to prove the line format, with a prefix check
/// standing in for authentication.
private enum FakeCipher {
    static let tag = Data("ok:".utf8)

    static func seal(_ data: Data) -> Data { tag + Data(data.reversed()) }

    static func open(_ data: Data) throws -> Data {
        guard data.starts(with: tag) else { throw Failure() }
        return Data(data.dropFirst(tag.count).reversed())
    }

    struct Failure: Error {}
}

struct SealedLinesTests {
    @Test func roundTripsRecordsInOrder() {
        let records = ["first", "second", "{\"text\":\"multi\\nline\"}"].map { Data($0.utf8) }
        let file = SealedLines.file(records: records, seal: FakeCipher.seal)
        let decoded = SealedLines.decode(file, open: FakeCipher.open)
        #expect(decoded.records == records)
        #expect(decoded.unreadable.isEmpty)
    }

    @Test func lineNeverContainsPlaintextOrStrayNewlines() {
        let record = Data("secret words\nmore".utf8)
        let line = SealedLines.line(for: record, seal: FakeCipher.seal)
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        #expect(String(decoding: line, as: UTF8.self).contains("secret") == false)
    }

    @Test func appendedLinesDecodeLikeARewrite() {
        var file = Data()
        file.append(SealedLines.line(for: Data("a".utf8), seal: FakeCipher.seal))
        file.append(SealedLines.line(for: Data("b".utf8), seal: FakeCipher.seal))
        #expect(SealedLines.decode(file, open: FakeCipher.open).records == [Data("a".utf8), Data("b".utf8)])
    }

    @Test func tornAndForeignLinesAreSetAsideNotFatal() {
        var file = SealedLines.line(for: Data("kept".utf8), seal: FakeCipher.seal)
        file.append(Data("not base64 at all!\n".utf8))
        // Valid base64, but sealed under some other key.
        file.append(Data("other".utf8).base64EncodedData())
        file.append(0x0A)
        // A crash mid-append leaves a truncated final line with no newline.
        let torn = SealedLines.line(for: Data("torn".utf8), seal: FakeCipher.seal).prefix(5)
        file.append(torn)

        let decoded = SealedLines.decode(file, open: FakeCipher.open)
        #expect(decoded.records == [Data("kept".utf8)])
        #expect(decoded.unreadable.count == 3)
    }

    @Test func rewritePreservesUnreadableLinesVerbatim() {
        let foreign = Data("b3RoZXI=".utf8)
        let file = SealedLines.file(records: [Data("x".utf8)], preserving: [foreign], seal: FakeCipher.seal)
        let decoded = SealedLines.decode(file, open: FakeCipher.open)
        #expect(decoded.records == [Data("x".utf8)])
        #expect(decoded.unreadable == [foreign])
    }

    @Test func emptyFileDecodesToNothing() {
        #expect(SealedLines.decode(Data(), open: FakeCipher.open) == SealedLines.Decoded())
    }
}

struct HistoryRetentionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 60 * 60

    @Test func defaultIsAMonth() {
        #expect(HistoryRetention.default == .month)
    }

    @Test func dayKeepsTheLast24Hours() {
        #expect(HistoryRetention.day.keeps(now.addingTimeInterval(-23 * hour), now: now))
        #expect(!HistoryRetention.day.keeps(now.addingTimeInterval(-25 * hour), now: now))
    }

    @Test func monthKeepsThirtyDays() {
        #expect(HistoryRetention.month.keeps(now.addingTimeInterval(-29 * 24 * hour), now: now))
        #expect(!HistoryRetention.month.keeps(now.addingTimeInterval(-31 * 24 * hour), now: now))
    }

    @Test func foreverKeepsEverything() {
        #expect(HistoryRetention.forever.keeps(.distantPast, now: now))
        #expect(HistoryRetention.forever.cutoff(now: now) == nil)
    }

    @Test func neverPersistsNothing() {
        #expect(!HistoryRetention.never.persists)
        #expect(!HistoryRetention.never.keeps(now.addingTimeInterval(-1), now: now))
        #expect(HistoryRetention.allCases.filter(\.persists) == [.day, .month, .forever])
    }
}
