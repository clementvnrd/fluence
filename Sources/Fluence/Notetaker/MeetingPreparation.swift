import AVFoundation
import EventKit
import FluenceCore
import Foundation

/// « Préparer les réunions » (FLU-45): asks the meeting permissions and downloads the
/// meeting models before any call, so that clicking *Enregistrer* in front of other people
/// brings up no macOS dialog and no wait.
///
/// Nothing runs on its own: only the button does (Settings › Réunions, or the onboarding's
/// meetings step), and never while a dictation or a meeting is in progress.
@MainActor
@Observable
final class MeetingPreparation {
    static let shared = MeetingPreparation()

    private(set) var state: MeetingReadiness.State
    private(set) var isRunning = false
    /// 0…1 while the models download; `nil` otherwise.
    private(set) var downloadProgress: Double?
    /// The last failure, in French, until the next attempt.
    private(set) var failure: String?

    private let defaults: UserDefaults
    /// Set by `SystemAudioTap` whenever a tap starts: by this button or by a real meeting.
    nonisolated static let systemAudioAskedKey = "meetingPreparation.systemAudioAsked"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = Self.read(systemAudioAsked: defaults.bool(forKey: Self.systemAudioAskedKey))
    }

    /// Grants can change in System Settings while Fluence runs: read again when shown.
    func refresh() {
        state = Self.read(systemAudioAsked: defaults.bool(forKey: Self.systemAudioAskedKey))
    }

    /// Whether the button may run now: not twice at once, and never during a recording.
    var canRun: Bool {
        !isRunning && !AppUpdater.shared.isBusy && !MeetingReadiness.steps(for: state).isEmpty
    }

    /// The steps still to run, limited to `only` when given: the onboarding's meetings step
    /// asks for the call's sound and downloads, and leaves the microphone and the calendar
    /// to their own steps.
    func pendingSteps(only: Set<MeetingReadiness.Step>? = nil) -> [MeetingReadiness.Step] {
        MeetingReadiness.steps(for: state).filter { only?.contains($0) ?? true }
    }

    func prepare(only: Set<MeetingReadiness.Step>? = nil) async {
        guard canRun, !pendingSteps(only: only).isEmpty else { return }
        isRunning = true
        failure = nil
        defer {
            isRunning = false
            downloadProgress = nil
            refresh()
        }

        for step in pendingSteps(only: only) {
            // A dictation started meanwhile: leave the rest for another click.
            guard !AppUpdater.shared.isBusy else { return }
            switch step {
            case .microphone:
                _ = await Permissions.requestMicrophone()
            case .systemAudio:
                await askForSystemAudio()
            case .calendar:
                _ = await Permissions.requestCalendar()
            case .download:
                await downloadModels()
            }
            refresh()
        }
    }

    // MARK: - Steps

    /// macOS asks for System Audio Recording the first time a process tap carries audio,
    /// and offers no public call to ask otherwise. So a global tap runs for two seconds,
    /// its audio dropped as it arrives, and the prompt appears. Whether the answer was yes
    /// cannot be read back: the state says "Demandé", not "Autorisé".
    private func askForSystemAudio() async {
        let tap = SystemAudioTap(app: nil)
        do {
            try tap.start { _ in }
            try? await Task.sleep(for: .seconds(2))
            tap.stop()
            Log.audio.info("meeting preparation: system audio asked")
        } catch {
            tap.stop()
            failure = "Le son des appels n'a pas pu être demandé : \(error.localizedDescription)"
            Log.audio.error("meeting preparation: system audio tap failed — \(error.localizedDescription, privacy: .public)")
            Diagnostics.error("meeting.preparation.systemTap", error)
        }
    }

    private func downloadModels() async {
        downloadProgress = 0
        do {
            try await MeetingSpeechModels.shared.downloadMissing { fraction in
                Task { @MainActor [weak self] in self?.noteProgress(fraction) }
            }
            Log.speech.info("meeting preparation: models ready")
        } catch {
            failure = "Téléchargement interrompu. Réessayez ; ce qui est déjà téléchargé est gardé."
            Log.speech.error("meeting preparation: download failed — \(error.localizedDescription, privacy: .public)")
            Diagnostics.error("meeting.preparation.download", error)
        }
    }

    private func noteProgress(_ fraction: Double) {
        // Progress reports arrive out of order from FluidAudio's queue; never go backwards.
        guard let current = downloadProgress else { return }
        downloadProgress = max(current, fraction)
    }

    // MARK: - Reading the current state

    private static func read(systemAudioAsked: Bool) -> MeetingReadiness.State {
        MeetingReadiness.State(
            microphone: grant(AVCaptureDevice.authorizationStatus(for: .audio)),
            systemAudio: systemAudioAsked ? .asked : .notAsked,
            calendar: NotetakerSettings.shared.useCalendar ? grant(EKEventStore.authorizationStatus(for: .event)) : nil,
            models: MeetingSpeechModels.models
        )
    }

    private static func grant(_ status: AVAuthorizationStatus) -> MeetingReadiness.Grant {
        switch status {
        case .authorized: .granted
        case .notDetermined: .undecided
        default: .refused
        }
    }

    private static func grant(_ status: EKAuthorizationStatus) -> MeetingReadiness.Grant {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .undecided
        // Write-only access cannot read titles or attendees: as good as refused here.
        default: .refused
        }
    }
}
