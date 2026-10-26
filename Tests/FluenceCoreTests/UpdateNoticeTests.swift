import Foundation
import Testing

@testable import FluenceCore

/// FLU-80: an update downloaded while Fluence lives in the menu bar.
struct UpdateRecordingTests {
    @Test func aMeetingWinsOverADictation() {
        #expect(UpdateRecording.from(dictating: false, meetingInProgress: false) == .none)
        #expect(UpdateRecording.from(dictating: true, meetingInProgress: false) == .dictation)
        #expect(UpdateRecording.from(dictating: false, meetingInProgress: true) == .meeting)
        #expect(UpdateRecording.from(dictating: true, meetingInProgress: true) == .meeting)
    }

    @Test func busyMeansTheSameAsTheUpdatePolicy() {
        for dictating in [false, true] {
            for meeting in [false, true] {
                #expect(
                    UpdateRecording.from(dictating: dictating, meetingInProgress: meeting).isBusy
                        == UpdatePolicy.isBusy(dictating: dictating, meetingInProgress: meeting)
                )
            }
        }
    }
}

struct UpdateMenuItemTests {
    @Test func hiddenWithoutAnUpdaterOrAWaitingVersion() {
        #expect(UpdateMenuItem.resolve(updaterRunning: false, readyVersion: "0.2.3", recording: .none) == .hidden)
        #expect(UpdateMenuItem.resolve(updaterRunning: true, readyVersion: nil, recording: .none) == .hidden)
        #expect(UpdateMenuItem.resolve(updaterRunning: true, readyVersion: "", recording: .meeting) == .hidden)
        #expect(UpdateMenuItem.hidden.title == nil)
        #expect(!UpdateMenuItem.hidden.isVisible)
    }

    @Test func readyInstallsInOneClick() {
        let item = UpdateMenuItem.resolve(updaterRunning: true, readyVersion: "0.2.3", recording: .none)
        #expect(item == .ready(version: "0.2.3"))
        #expect(item.isVisible)
        #expect(item.isEnabled)
        // No « … »: nothing else to confirm after the click.
        #expect(item.title == "Installer Fluence 0.2.3")
        #expect(item.subtitle == nil)
    }

    @Test func greyedOutUntilTheRecordingEnds() {
        let meeting = UpdateMenuItem.resolve(updaterRunning: true, readyVersion: "0.2.3", recording: .meeting)
        #expect(meeting == .waitingForMeeting(version: "0.2.3"))
        #expect(!meeting.isEnabled)
        #expect(meeting.title == "Installer Fluence 0.2.3")
        #expect(meeting.subtitle == "À la fin de la réunion")

        let dictation = UpdateMenuItem.resolve(updaterRunning: true, readyVersion: "0.2.3", recording: .dictation)
        #expect(dictation == .waitingForDictation(version: "0.2.3"))
        #expect(!dictation.isEnabled)
        #expect(dictation.subtitle == "À la fin de la dictée")
    }

    @Test func neverBothUpdateItemsInTheMenu() {
        #expect(UpdateMenuItem.showsCheckForUpdates(updaterRunning: true, readyVersion: nil))
        #expect(!UpdateMenuItem.showsCheckForUpdates(updaterRunning: true, readyVersion: "0.2.3"))
        // A dev build without a feed has neither.
        #expect(!UpdateMenuItem.showsCheckForUpdates(updaterRunning: false, readyVersion: nil))
        for recording in [UpdateRecording.none, .dictation, .meeting] {
            for version in [nil, "0.2.3"] as [String?] {
                let top = UpdateMenuItem.resolve(updaterRunning: true, readyVersion: version, recording: recording)
                #expect(top.isVisible != UpdateMenuItem.showsCheckForUpdates(updaterRunning: true, readyVersion: version))
            }
        }
    }

    @Test func dotWhileAVersionWaitsWhateverRecords() {
        #expect(UpdateMenuItem.showsDot(updaterRunning: true, readyVersion: "0.2.3"))
        #expect(!UpdateMenuItem.showsDot(updaterRunning: true, readyVersion: nil))
        #expect(!UpdateMenuItem.showsDot(updaterRunning: false, readyVersion: "0.2.3"))
    }
}

struct UpdateNotificationPolicyTests {
    private func post(
        ready: String? = "0.2.3", notified: String? = nil, asked: Bool = false, active: Bool = false, busy: Bool = false
    ) -> Bool {
        UpdateNotificationPolicy.shouldPost(
            readyVersion: ready, notifiedVersion: notified, alreadyAsked: asked, appIsActive: active, isBusy: busy
        )
    }

    @Test func postsWhenFluenceStaysInTheBackground() {
        #expect(post())
        // An older version was notified: the new one gets its own notification.
        #expect(post(notified: "0.2.2"))
    }

    @Test func oncePerVersion() {
        #expect(!post(notified: "0.2.3"))
    }

    @Test func notWhileFluenceIsInFront() {
        // The question « Fluence x.y.z est disponible » is asked instead.
        #expect(!post(active: true))
        #expect(!post(asked: true))
    }

    @Test func waitsForTheRecordingToEnd() {
        #expect(!post(busy: true))
        // The same version, once the recording has ended and Fluence is still behind.
        #expect(post(busy: false))
    }

    @Test func nothingWithoutAVersion() {
        #expect(!post(ready: nil))
        #expect(!post(ready: ""))
    }

    @Test func frenchTexts() {
        #expect(UpdateNotificationPolicy.title(version: "0.2.3") == "Fluence 0.2.3 est prête")
        #expect(UpdateNotificationPolicy.body == "Installer prend quelques secondes.")
        #expect(UpdateNotificationPolicy.installTitle == "Installer")
    }

    @Test func aBannerClickNeverAsksTwiceInARow() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(UpdateNotificationPolicy.bannerClickAsksAgain(lastAnswer: nil, now: now))
        #expect(!UpdateNotificationPolicy.bannerClickAsksAgain(lastAnswer: now.addingTimeInterval(-1), now: now))
        #expect(UpdateNotificationPolicy.bannerClickAsksAgain(lastAnswer: now.addingTimeInterval(-60), now: now))
    }
}
