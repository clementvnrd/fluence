import FluenceCore
import FluidAudio
import Foundation
import Observation

/// Parakeet Ultra's download, asked for and watched (FLU-29).
///
/// French and Auto default to Parakeet, but its ~600 MB are fetched only once the user says
/// so — the onboarding's « Télécharger », or the card in Réglages › Transcription — never at a
/// key-down. Until the model is complete on disk Apple's engine takes the dictations, and the
/// capsule shows the download's progress in its icon slot. One download for the whole app:
/// every place that shows it reads this object.
@MainActor
@Observable
final class ParakeetDownload {
    static let shared = ParakeetDownload()

    enum Phase: Equatable {
        case idle
        /// 0…1 of the bytes.
        case downloading(Double)
        case failed
    }

    private(set) var phase: Phase = .idle
    /// The model is complete on disk. Read from the disk at launch, after a download, and
    /// whenever `refresh()` is called (every key-down); views read this, never the disk.
    private(set) var isReady: Bool

    /// What the UI announces (`MeetingSpeechModels.Kind.speech` says the same).
    static let totalBytes: Int64 = 600_000_000

    @ObservationIgnored private var task: Task<Void, Never>?

    private init() {
        isReady = ParakeetModels.isDownloaded
    }

    /// The progress while downloading, else nil.
    var fraction: Double? {
        if case .downloading(let fraction) = phase { return fraction }
        return nil
    }

    var isDownloading: Bool { fraction != nil }

    /// Reads the disk again: a model deleted from Réglages, or fetched by the meetings'
    /// preparation, shows here.
    @discardableResult
    func refresh() -> Bool {
        isReady = ParakeetModels.isDownloaded
        return isReady
    }

    /// Starts the download, unless the model is already there or on its way.
    func start() {
        guard task == nil, !refresh() else { return }
        phase = .downloading(0)
        attempt += 1
        let attempt = self.attempt
        Log.speech.info("Parakeet: download started (asked for)")
        // The shared instance lives as long as the app: no weak capture to juggle.
        task = Task {
            do {
                try await ParakeetModels.download { fraction in
                    Task { @MainActor in ParakeetDownload.shared.progressed(fraction, attempt: attempt) }
                }
                self.finished(nil, attempt: attempt)
            } catch {
                self.finished(error, attempt: attempt)
            }
        }
    }

    /// Tells one start from the next, so a cancelled download's late reports change nothing.
    @ObservationIgnored private var attempt = 0

    /// ✕: stops the download. What already arrived stays in FluidAudio's cache and the next
    /// attempt resumes from it.
    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        phase = .idle
        Log.speech.info("Parakeet: download cancelled")
    }

    private func progressed(_ fraction: Double, attempt: Int) {
        // A late progress report must not bring back a download that ended or was cancelled.
        guard attempt == self.attempt, task != nil, case .downloading(let shown) = phase else { return }
        // FluidAudio reports per file and can step back a hair between two; the bar never does.
        phase = .downloading(max(shown, fraction))
    }

    private func finished(_ error: Error?, attempt: Int) {
        // Cancelled (`cancel()` already put everything back), or an older attempt.
        guard attempt == self.attempt, task != nil else { return }
        task = nil
        if let error {
            Log.speech.error("Parakeet: download failed — \(error.localizedDescription)")
            Diagnostics.error("speech.parakeet.download", error)
            phase = .failed
            refresh()
            return
        }
        phase = .idle
        if refresh() {
            Log.speech.info("Parakeet: download complete")
            // The next dictation runs on Parakeet; load it now rather than on that key-down.
            Settings.shared.prewarmCurrentEngine()
        } else {
            // FluidAudio said done but the folder is not whole: say it failed, so « Réessayer »
            // shows, rather than a silent Apple forever.
            Log.speech.error("Parakeet: download ended but the model folder is incomplete")
            Diagnostics.error("speech.parakeet.incomplete")
            phase = .failed
        }
    }
}
