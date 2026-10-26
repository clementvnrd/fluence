import Foundation
import Testing

@testable import FluenceCore

private let nbsp = "\u{00A0}"

private func row(
    _ engine: String,
    _ seconds: Double,
    text: String = "Bonjour à tous.",
    audio: Double = 5,
    failed: Bool? = false,
    timing: ComparisonRow.Timing = .compute
) -> ComparisonRow {
    ComparisonRow(engine: engine, seconds: seconds, audioSeconds: audio, text: text, failed: failed, timing: timing)
}

struct ComparisonPlanTests {
    @Test func aFreshAccountComparesAppleAloneAndDownloadsNothing() {
        #expect(ComparisonPlan.engines(parakeetOnDisk: false, whisperOnDisk: false) == [.apple])
    }

    @Test func parakeetAndWhisperJoinOnlyOnceOnDisk() {
        #expect(ComparisonPlan.engines(parakeetOnDisk: true, whisperOnDisk: false) == [.apple, .parakeet])
        #expect(ComparisonPlan.engines(parakeetOnDisk: false, whisperOnDisk: true) == [.apple, .whisper])
        #expect(ComparisonPlan.engines(parakeetOnDisk: true, whisperOnDisk: true) == [.apple, .parakeet, .whisper])
    }

    @Test func waitsForAnOutsideAppOnlyWhenFluencePressedItsKey() {
        #expect(ComparisonPlan.waitsForExternalResult(installed: true, keyPressedByFluence: true))
        // A hotkey comparison: the outside app is installed but never heard anything.
        #expect(!ComparisonPlan.waitsForExternalResult(installed: true, keyPressedByFluence: false))
        #expect(!ComparisonPlan.waitsForExternalResult(installed: false, keyPressedByFluence: true))
        #expect(!ComparisonPlan.waitsForExternalResult(installed: false, keyPressedByFluence: false))
    }

    @Test func theStampWindowSpansTheHoldStartUpToTheRelease() {
        let start = Date(timeIntervalSince1970: 1_000)
        let window = ComparisonPlan.externalStampWindow(
            holdStarted: start, releasedAt: start.addingTimeInterval(3), previousReleasedAt: nil
        )
        #expect(window.lowerBound == start.addingTimeInterval(-5))
        // Nothing that began after the release belongs to this recording.
        #expect(window.upperBound == start.addingTimeInterval(3))
    }

    @Test func theStampWindowStopsAtTheSlackOnALongHold() {
        let start = Date(timeIntervalSince1970: 1_000)
        let window = ComparisonPlan.externalStampWindow(
            holdStarted: start, releasedAt: start.addingTimeInterval(30), previousReleasedAt: nil
        )
        #expect(window.upperBound == start.addingTimeInterval(5))
    }

    @Test func theStampWindowKeepsTheRecordingBeforeOut() {
        let start = Date(timeIntervalSince1970: 1_000)
        let previous = start.addingTimeInterval(-2)
        let window = ComparisonPlan.externalStampWindow(
            holdStarted: start, releasedAt: start.addingTimeInterval(3), previousReleasedAt: previous
        )
        #expect(window.lowerBound == previous)
        // A previous release long before changes nothing.
        let old = ComparisonPlan.externalStampWindow(
            holdStarted: start, releasedAt: start.addingTimeInterval(3), previousReleasedAt: start.addingTimeInterval(-60)
        )
        #expect(old.lowerBound == start.addingTimeInterval(-5))
    }

    @Test func aVeryShortHoldStillLeavesASecondForALateApp() {
        let start = Date(timeIntervalSince1970: 1_000)
        let window = ComparisonPlan.externalStampWindow(
            holdStarted: start, releasedAt: start.addingTimeInterval(0.1), previousReleasedAt: nil
        )
        #expect(window.upperBound == start.addingTimeInterval(1))
    }
}

struct ComparisonRowTests {
    @Test func aFailedEngineShowsEchecNotARatio() {
        let failed = row("Parakeet", 0, text: ComparisonRow.startFailure, failed: true)
        #expect(failed.status == .failed)
        #expect(failed.realtimeFactor == nil)
        #expect(failed.speedLabel == "échec")
        #expect(failed.displayText == "Le moteur n'a pas pu démarrer.")
    }

    @Test func anOlderWarningRowReadsAsAFailureInFrench() {
        // Saved before the flag existed, with the engine's English error text.
        let legacy = row("Parakeet", 0, text: "⚠️ The operation couldn't be completed.", failed: nil)
        #expect(legacy.status == .failed)
        #expect(legacy.speedLabel == "échec")
        #expect(legacy.displayText == ComparisonRow.genericFailure)
    }

    @Test func aWorkingRowShowsItsRealTimeFactor() {
        let ok = row("Apple", 0.5, audio: 5)
        #expect(ok.status == .transcribed)
        #expect(ok.realtimeFactor == 10)
        #expect(ok.speedLabel == "10×\(nbsp)temps réel")
        #expect(ok.displayText == "Bonjour à tous.")
    }

    @Test func noTimeMeansNoRatio() {
        #expect(row("Apple", 0).realtimeFactor == nil)
        #expect(row("Apple", .nan).realtimeFactor == nil)
        #expect(row("Apple", 0.5, audio: 0).realtimeFactor == nil)
    }

    @Test func anEngineThatHeardNothingSaysSo() {
        let empty = row("Whisper", 0.3, text: "  ")
        #expect(empty.status == .heardNothing)
        #expect(empty.displayText == "(rien de reconnu)")
    }

    @Test func anEndToEndLatencyHasNoRealTimeFactor() {
        let wispr = row("Wispr Flow", 1.2, timing: .endToEnd)
        #expect(wispr.realtimeFactor == nil)
        #expect(wispr.speedLabel == "réseau compris")
    }
}

struct ComparisonRankingTests {
    @Test func localEnginesAreRankedByComputeTimeAndTheNetworkLatencyStandsApart() {
        let ranking = ComparisonRanking([
            row("Apple", 0.40),
            row("Wispr Flow", 0.05, timing: .endToEnd),
            row("Parakeet", 0.10),
        ])
        #expect(ranking.local.map(\.engine) == ["Parakeet", "Apple"])
        #expect(ranking.endToEnd.map(\.engine) == ["Wispr Flow"])
        // Wispr's smaller number does not make it the winner: it is not the same clock.
        #expect(ranking.winner?.engine == "Parakeet")
    }

    @Test func aFailedEngineNeverWinsNorSetsTheMargin() {
        let ranking = ComparisonRanking([
            row("Apple", 0.40),
            row("Parakeet", 0, text: ComparisonRow.startFailure, failed: true),
            row("Whisper", 0.80),
        ])
        #expect(ranking.local.map(\.engine) == ["Apple", "Whisper", "Parakeet"])
        #expect(ranking.winner?.engine == "Apple")
        #expect(ranking.margin == .ahead(engine: "Apple", ratio: 2, seconds: 0.4))
        #expect(ranking.marginLabel == "Apple : 2,0× plus rapide · 0,40\(nbsp)s d'avance")
    }

    @Test func oneWorkingEngineHasNoWinnerAndNoMargin() {
        let ranking = ComparisonRanking([
            row("Apple", 0.40),
            row("Parakeet", 0, text: "⚠️ boom", failed: nil),
        ])
        #expect(ranking.winner == nil)
        #expect(ranking.margin == nil)
        #expect(ranking.marginLabel == nil)
    }

    @Test func anEngineThatHeardNothingRanksAfterTheOnesThatDid() {
        let ranking = ComparisonRanking([
            row("Apple", 0.40),
            row("Whisper", 0.01, text: ""),
            row("Parakeet", 0.20),
        ])
        #expect(ranking.local.map(\.engine) == ["Parakeet", "Apple", "Whisper"])
        #expect(ranking.winner?.engine == "Parakeet")
    }

    @Test func nearlyEqualTimesAreATie() {
        let ranking = ComparisonRanking([row("Apple", 0.400), row("Parakeet", 0.402)])
        #expect(ranking.margin == .tied)
        #expect(ranking.marginLabel == "à égalité")
    }

    @Test func theVerdictIgnoresFailuresAndFormatting() {
        #expect(ComparisonRanking([
            row("Apple", 0.4, text: "Bonjour à tous."),
            row("Parakeet", 0.1, text: "bonjour à tous"),
            row("Whisper", 0, text: "⚠️ boom", failed: true),
        ]).verdict == .sameWords)
        #expect(ComparisonRanking([
            row("Apple", 0.4, text: "Bonjour."),
            row("Parakeet", 0.1, text: "Bonjour."),
        ]).verdict == .identical)
        #expect(ComparisonRanking([
            row("Apple", 0.4, text: "Bonjour à tous."),
            row("Wispr Flow", 1.1, text: "Bonsoir à tous.", timing: .endToEnd),
        ]).verdict == .differentWords)
        // A failure next to a single result compares nothing.
        #expect(ComparisonRanking([
            row("Apple", 0.4),
            row("Parakeet", 0, text: ComparisonRow.startFailure, failed: true),
        ]).verdict == nil)
    }
}

struct FrenchListTests {
    @Test func listsJoinTheLastItemWithEt() {
        #expect(FrenchFormat.list([]) == "")
        #expect(FrenchFormat.list(["Apple"]) == "Apple")
        #expect(FrenchFormat.list(["Apple", "Parakeet"]) == "Apple et Parakeet")
        #expect(FrenchFormat.list(["Apple", "Parakeet", "Whisper"]) == "Apple, Parakeet et Whisper")
    }
}
