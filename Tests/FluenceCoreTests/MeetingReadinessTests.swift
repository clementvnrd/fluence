import Foundation
import Testing

@testable import FluenceCore

struct MeetingReadinessTests {
    private static let speech = MeetingReadiness.Model(name: "Reconnaissance vocale", megabytes: 600, isPresent: false)
    private static let voice = MeetingReadiness.Model(name: "Détection de la voix", megabytes: 2, isPresent: true)
    private static let echo = MeetingReadiness.Model(name: "Annulation d'écho", megabytes: 19, isPresent: false)

    private static func state(
        microphone: MeetingReadiness.Grant = .granted,
        systemAudio: MeetingReadiness.SoundAccess = .asked,
        calendar: MeetingReadiness.Grant? = .granted,
        models: [MeetingReadiness.Model] = []
    ) -> MeetingReadiness.State {
        MeetingReadiness.State(microphone: microphone, systemAudio: systemAudio, calendar: calendar, models: models)
    }

    @Test func aFreshInstallAsksEverythingThenDownloads() {
        let fresh = Self.state(
            microphone: .undecided, systemAudio: .notAsked, calendar: .undecided,
            models: [Self.speech, Self.voice, Self.echo]
        )
        #expect(MeetingReadiness.steps(for: fresh) == [.microphone, .systemAudio, .calendar, .download])
        #expect(fresh.missingMegabytes == 619)
        #expect(!fresh.isReady)
        #expect(MeetingReadiness.actionTitle(fresh) == "Préparer")
    }

    @Test func aCalendarSwitchedOffIsNeitherAskedNorWaitedFor() {
        let noCalendar = Self.state(calendar: nil)
        #expect(MeetingReadiness.steps(for: noCalendar).isEmpty)
        #expect(noCalendar.isReady)
    }

    @Test func refusalsAreNotAskedAgain() {
        // macOS shows its prompt once; after a refusal only System Settings can change it.
        let refused = Self.state(microphone: .refused, calendar: .refused)
        #expect(MeetingReadiness.steps(for: refused).isEmpty)
        #expect(!refused.isReady, "no meeting can be recorded without the microphone")
        #expect(Self.state(calendar: .refused).isReady, "the calendar is optional")
    }

    @Test func onlyDownloadsLeftSaysSo() {
        let downloads = Self.state(models: [Self.speech, Self.voice])
        #expect(MeetingReadiness.steps(for: downloads) == [.download])
        #expect(MeetingReadiness.actionTitle(downloads) == "Télécharger")
        #expect(MeetingReadiness.actionTitle(Self.state(models: [Self.voice])) == "Tout est prêt")
    }

    @Test func modelsLabelGivesSizeThenProgress() {
        let space = FrenchFormat.space
        #expect(MeetingReadiness.modelsLabel(Self.state(models: [Self.speech, Self.echo]), progress: nil) == "619\(space)Mo à télécharger")
        #expect(MeetingReadiness.modelsLabel(Self.state(models: [Self.voice]), progress: nil) == "Prêts")
        #expect(MeetingReadiness.modelsLabel(Self.state(), progress: 0.427) == "Téléchargement…\(space)42\(space)%")
        #expect(MeetingReadiness.modelsLabel(Self.state(), progress: 1.5) == "Téléchargement…\(space)100\(space)%")
    }

    @Test func labelsAreFrench() {
        #expect(MeetingReadiness.label(.granted) == "Autorisé")
        #expect(MeetingReadiness.label(.undecided) == "À autoriser")
        #expect(MeetingReadiness.label(.refused) == "Refusé")
        #expect(MeetingReadiness.label(.asked) == "Demandé")
        #expect(MeetingReadiness.label(.notAsked) == "À demander")
    }
}
