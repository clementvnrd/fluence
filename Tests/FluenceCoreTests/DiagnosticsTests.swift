import Foundation
import Testing

@testable import FluenceCore

/// FLU-35: the diagnostic file must say what went wrong without saying anything the user
/// dictated, recorded or is called.
struct DiagnosticsTests {
    /// A sentence nobody would type into a setting or an error kind: if any of its words shows
    /// up in a report, text leaked.
    static let planted = "Zéphyrin grignote quatorze clafoutis indigo chez Mlle Brocéliande"
    static let plantedWords = ["Zéphyrin", "Zephyrin", "grignote", "quatorze", "clafoutis", "indigo", "Brocéliande", "Broceliande"]

    static func assertNoPlantedWord(_ report: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for word in plantedWords {
            #expect(!report.localizedCaseInsensitiveContains(word), "\(word) leaked into the report", sourceLocation: sourceLocation)
        }
    }

    // MARK: - The planted sentence

    /// Every string slot of the report gets the sentence, or a path and names holding it; none
    /// of it may come out.
    @Test func aPlantedSentenceNeverReachesTheReport() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let home = "/Users/brocéliande"
        let input = DiagnosticReport.Input(
            generatedAt: date,
            app: [("version", "0.2.0"), ("hostName", "MacBook de Brocéliande"), ("note", Self.planted)],
            settings: [
                ("engine", "parakeet"),
                ("whisperModel", Self.planted),
                (Self.planted, "on"),
                ("supportFolder", "\(home)/Library/Application Support/Fluence"),
                // Not planted: one ASCII word *is* a valid token. Keeping free text out of the
                // settings is the caller's job (`DiagnosticExport` passes enum values only),
                // checked end to end by `Fluence --selftest`.
            ],
            counts: [("dictations", 3), (Self.planted, 1)],
            timings: [("dictation.process.median", 0.42), ("quatorze clafoutis", 1)],
            events: [
                DiagnosticEvent(kind: "history.write", severity: .error, code: 13, domain: "NSCocoaErrorDomain", at: date),
                DiagnosticEvent(kind: Self.planted, severity: .error, at: date),
                DiagnosticEvent(kind: "dictation.failed", severity: .error, domain: Self.planted, at: date),
            ].compactMap { $0 },
            crashReportFiles: [
                "Fluence-2026-10-08-101500.ips",
                "Fluence_2026-10-09-111111_MacBook-de-Broceliande.diag",
                "Fluence.cpu_resource_2026-10-10-121212_Zephyrin-iMac.diag",
                "\(Self.planted).ips",
            ],
            redact: [home, "brocéliande", "MacBook de Brocéliande"]
        )

        let report = DiagnosticReport.render(input)

        Self.assertNoPlantedWord(report)
        #expect(!report.contains("/Users/"))
        // What is allowed still gets through.
        #expect(report.contains("version: 0.2.0"))
        #expect(report.contains("engine: parakeet"))
        #expect(report.contains("dictations: 3"))
        #expect(report.contains("dictation.process.median: 0.420 s"))
        #expect(report.contains("error history.write domain=NSCocoaErrorDomain code=13"))
        #expect(report.contains("error dictation.failed"))
        #expect(report.contains("Fluence-2026-10-08-101500.ips"))
        #expect(report.contains("Fluence-2026-10-09-111111.diag"))
        #expect(report.contains("Fluence-2026-10-10-121212.diag"))
        #expect(report.contains("[crash reports] 3"))
    }

    @Test func redactionCatchesWhatTheTokensWouldLetThrough() {
        // An ASCII user name is a valid token: only `redact` keeps it out.
        let input = DiagnosticReport.Input(
            generatedAt: .now,
            app: [("account", "clement"), ("home", "/Users/clement")],
            redact: ["/Users/clement", "clement"]
        )
        let report = DiagnosticReport.render(input)
        #expect(!report.localizedCaseInsensitiveContains("clement"))
        #expect(report.contains("account: •••"))
    }

    // MARK: - Tokens

    @Test func tokensRefuseTextPathsAndNames() {
        #expect(DiagnosticToken.identifier("history.write") == "history.write")
        #expect(DiagnosticToken.identifier("openai_whisper-small") == "openai_whisper-small")
        for bad in ["", "two words", "é", "a/b", "~/x", String(repeating: "a", count: 81), "line\nbreak", "quote\"", "Clément"] {
            #expect(DiagnosticToken.identifier(bad) == nil, "\(bad) should be refused")
        }
        #expect(DiagnosticToken.value("Apple (streaming)") == "Apple (streaming)")
        #expect(DiagnosticToken.value("Version 26.1 (Build 25B78)") == "Version 26.1 (Build 25B78)")
        #expect(DiagnosticToken.value("/Users/x") == nil)
        #expect(DiagnosticToken.value("Bonjour, ça va ?") == nil)
    }

    // MARK: - Crash report names

    @Test func crashReportsAreListedByDateAndTypeOnly() {
        #expect(CrashReportName.listed("Fluence-2026-10-08-101500.ips") == "Fluence-2026-10-08-101500.ips")
        #expect(CrashReportName.listed("Fluence_2026-10-08-101500_MacBook-Pro-de-Clement.crash") == "Fluence-2026-10-08-101500.crash")
        #expect(CrashReportName.listed("Fluence.wakeups_resource_2026-10-08-101500_Mac.diag") == "Fluence-2026-10-08-101500.diag")
        #expect(CrashReportName.listed("Fluence-2026-10-08-101500.ips.ca.synced") == nil)
        #expect(CrashReportName.listed("FluenceHelper-2026-10-08-101500.ips") == nil)
        #expect(CrashReportName.listed("SFA-ckks.json_2026-10-22-073708_Macbook-Air-M2.diag") == nil)
        #expect(CrashReportName.listed("Fluence.ips") == nil)
    }

    // MARK: - Ring

    @Test func theRingKeepsTheLastTwoHundredOldestFirst() throws {
        var ring = DiagnosticRing()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<250 {
            ring.record(try #require(DiagnosticEvent(kind: "kind.\(index)", severity: .error, at: start + Double(index))))
        }
        #expect(ring.events.count == DiagnosticRing.capacity)
        #expect(ring.events.first?.kind == "kind.50")
        #expect(ring.events.last?.kind == "kind.249")
    }

    @Test func repeatsInARowAreFolded() throws {
        var ring = DiagnosticRing()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for second in 0..<500 {
            ring.record(try #require(DiagnosticEvent(kind: "audio.convert", severity: .error, code: -50, at: start + Double(second))))
        }
        ring.record(try #require(DiagnosticEvent(kind: "audio.convert", severity: .error, code: -10, at: start + 600)))
        ring.record(try #require(DiagnosticEvent(kind: "hotkey.eventTap.rearmed", severity: .recovery, at: start + 700)))
        #expect(ring.events.count == 3)
        #expect(ring.events[0].count == 500)
        #expect(ring.events[0].first == start)
        #expect(ring.events[0].last == start + 499)
        #expect(ring.events[1].code == -10)
        #expect(ring.events[2].severity == .recovery)
    }

    @Test func theRingRoundTripsAndDropsWhatIsNotAnIdentifier() throws {
        var ring = DiagnosticRing()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        ring.record(try #require(DiagnosticEvent(kind: "history.write", severity: .error, code: 13, domain: "NSCocoaErrorDomain", at: date)))
        ring.record(try #require(DiagnosticEvent(kind: "meeting.recovered", severity: .recovery, at: date + 1)))
        #expect(DiagnosticRing.decoded(try ring.encoded()) == ring)

        // A file edited by hand: one entry carries a sentence, one is not even an event.
        let edited = """
        {"events":[
          {"kind":"history.write","severity":"error","first":"2027-01-15T08:00:00Z","last":"2027-01-15T08:00:00Z","count":1},
          {"kind":"\(Self.planted)","severity":"error","first":"2027-01-15T08:00:00Z","last":"2027-01-15T08:00:00Z","count":1},
          {"kind":"meeting.failed","severity":"error","domain":"\(Self.planted)","first":"2027-01-15T08:00:00Z","last":"2027-01-15T08:00:00Z","count":2},
          42,
          {"kind":"dictation.failed","severity":"error","first":"2027-01-15T08:00:00Z","last":"2027-01-15T08:00:00Z","count":1}
        ]}
        """
        let decoded = try #require(DiagnosticRing.decoded(Data(edited.utf8)))
        #expect(decoded.events.map(\.kind) == ["history.write", "meeting.failed", "dictation.failed"])
        #expect(decoded.events[1].domain == nil)
        #expect(DiagnosticRing.decoded(Data("not json".utf8)) == nil)
    }

    @Test func eventsWithTextAreRefusedAtTheSource() {
        #expect(DiagnosticEvent(kind: Self.planted, severity: .error, at: .now) == nil)
        #expect(DiagnosticEvent(kind: "ok.kind", severity: .error, domain: "/Users/x/Library", at: .now)?.domain == nil)
    }

    // MARK: - Timings

    @Test func percentilesUseTheNearestRank() {
        #expect(DiagnosticStats.percentile([], 0.5) == nil)
        #expect(DiagnosticStats.percentile([3], 0.9) == 3)
        #expect(DiagnosticStats.percentile([1, 2, 3, 4], 0.5) == 2)
        #expect(DiagnosticStats.percentile([4, 1, 3, 2, 5, 6, 7, 8, 9, 10], 0.9) == 9)
        #expect(DiagnosticStats.percentile([1, .nan, 2], 1) == 2)
    }
}
