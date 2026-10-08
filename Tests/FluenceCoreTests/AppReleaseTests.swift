import Foundation
import Testing

@testable import FluenceCore

struct ReleaseVersionTests {
    @Test func buildNumbersFollowTheVersion() {
        #expect(ReleaseVersion("0.1.0")?.buildNumber == 100)
        #expect(ReleaseVersion("0.1.1")?.buildNumber == 101)
        #expect(ReleaseVersion("0.2.0")?.buildNumber == 200)
        #expect(ReleaseVersion("1.0.0")?.buildNumber == 10_000)
        #expect(ReleaseVersion("12.34.56")?.buildNumber == 123_456)
    }

    @Test func everyReleaseIsAboveTheUnversionedBuilds() throws {
        // The builds installed before FLU-26 say 1.0.0 (build 1). Sparkle compares build numbers.
        let first = try #require(ReleaseVersion("0.1.0"))
        #expect(first.buildNumber > 1)
    }

    @Test func orderIsKeptAcrossMinorAndMajor() throws {
        let versions = try ["0.1.0", "0.1.1", "0.1.99", "0.2.0", "0.10.0", "1.0.0", "1.0.1"]
            .map { try #require(ReleaseVersion($0)) }
        #expect(versions == versions.sorted())
        #expect(zip(versions, versions.dropFirst()).allSatisfy { $0.buildNumber < $1.buildNumber })
    }

    @Test func malformedVersionsAreRefused() {
        for bad in ["", "1", "1.0", "1.0.0.0", "1.0.x", "1..0", "-1.0.0", "1.100.0", "1.0.100", "v1.0.0", "1.0.0-beta", "١.٢.٣", "1.0.²"] {
            #expect(ReleaseVersion(bad) == nil, "\(bad) should be refused")
        }
    }

    /// The version in `Resources/Info.plist` is the one source of truth for `make release`:
    /// its build number must be the one derived from it, or Sparkle would order releases wrong.
    @Test func infoPlistBuildMatchesItsVersion() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let short = try #require(info["CFBundleShortVersionString"] as? String)
        let build = try #require(info["CFBundleVersion"] as? String)
        let version = try #require(ReleaseVersion(short), "CFBundleShortVersionString must look like 1.2.3")
        #expect(build == String(version.buildNumber))
    }
}

struct UpdatePolicyTests {
    @Test func busyWhileDictatingOrInAMeeting() {
        #expect(UpdatePolicy.isBusy(dictating: true, meetingInProgress: false))
        #expect(UpdatePolicy.isBusy(dictating: false, meetingInProgress: true))
        #expect(!UpdatePolicy.isBusy(dictating: false, meetingInProgress: false))
    }

    @Test func neverOffersDuringARecordingOrOverAnotherApp() {
        #expect(UpdatePolicy.mayOffer(isBusy: false, appIsActive: true))
        #expect(!UpdatePolicy.mayOffer(isBusy: true, appIsActive: true))
        #expect(!UpdatePolicy.mayOffer(isBusy: false, appIsActive: false))
    }

    @Test func neverRelaunchesDuringARecording() {
        #expect(UpdatePolicy.mayRelaunch(isBusy: false))
        #expect(!UpdatePolicy.mayRelaunch(isBusy: true))
    }
}

struct ReleaseNotesTextTests {
    @Test func listsBecomeLinesAndTheHeadingGoes() {
        let html = "<h2>Fluence 0.1.1</h2><ul><li>Mises à jour en un clic</li><li>Dictée &amp; réunions</li></ul>"
        #expect(ReleaseNotesText.summary(fromHTML: html) == "• Mises à jour en un clic\n• Dictée & réunions")
    }

    @Test func theShippedNotesFitThePrompt() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/releases/0.1.0.html")
        let summary = try #require(ReleaseNotesText.summary(fromHTML: try String(contentsOf: url, encoding: .utf8)))
        #expect(!summary.contains("Fluence 0.1.0"))
        #expect(!summary.hasSuffix("…"))
    }

    @Test func longNotesAreCutOnAWord() throws {
        let html = "<p>" + String(repeating: "mot ", count: 200) + "</p>"
        let summary = try #require(ReleaseNotesText.summary(fromHTML: html, limit: 50))
        #expect(summary.count <= 51)
        #expect(summary.hasSuffix("…"))
        #expect(!summary.contains("mo…"))
    }

    @Test func emptyNotesGiveNothing() {
        #expect(ReleaseNotesText.summary(fromHTML: nil) == nil)
        #expect(ReleaseNotesText.summary(fromHTML: "<p> </p>") == nil)
    }
}
