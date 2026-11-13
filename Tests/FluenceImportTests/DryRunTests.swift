import FluenceCore
import Foundation
import Testing
@testable import FluenceImport

/// FLU-144, by hand only: `FLUENCE_IMPORT_DRYRUN=1 swift test --filter DryRun` reads this Mac's
/// real Wispr Flow / superwhisper / Granola files read-only and prints COUNTS ONLY — never a
/// text, title or name — to prove the readers understand the real formats. It writes nothing,
/// and compares against an empty Fluence (what a first import would add) with a 30-day history.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FLUENCE_IMPORT_DRYRUN"] != nil))
struct DryRunTests {
    @Test func countsOnThisMac() {
        let started = Date()
        let scans = ImportScanner.scan(ImportLocations(home: FileManager.default.homeDirectoryForCurrentUser), includeDocuments: false)
        let read = Date().timeIntervalSince(started)
        let sources = scans.compactMap(\.data)
        let all = Set(ImportApp.allCases.flatMap { app in ImportKind.allCases.map { ImportChoice(app, $0) } })
        for retention in [HistoryRetention.month, .forever] {
            let plan = ImportPlanner.plan(sources, selection: all, retention: retention, now: Date(), existing: ImportExisting(), userNames: [])
            print("== dry run, history \(retention.rawValue), read in \(String(format: "%.2f", read)) s")
            for scan in scans {
                print("\(scan.app.name): found \(scan.isFound), readable \(scan.data != nil)")
                guard let data = scan.data else { continue }
                print("  read: \(data.entries.count) entries, \(data.snippets.count) snippets, \(data.dictations.count) dictations, "
                    + "\(data.meetings.filter { !$0.isNote }.count) meetings (\(data.meetings.filter { !$0.isNote && !$0.transcript.turns.isEmpty }.count) with a transcript, "
                    + "\(data.meetings.reduce(0) { $0 + $1.transcript.turns.count }) turns), \(data.meetings.filter(\.isNote).count) notes")
                for kind in ImportKind.allCases {
                    let tally = plan.tally(scan.app, kind)
                    print("  \(kind): to import \(tally.toImport) (notes \(tally.notes)), left aside \(tally.leftAside), duplicates \(tally.duplicates)")
                }
            }
        }
    }
}
