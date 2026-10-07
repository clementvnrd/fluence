import AVFoundation
import Foundation

/// The microphone side of a meeting: "me".
///
/// Its own `AVAudioEngine`, independent of the dictation `AudioCapture`, so holding the
/// dictation key during a call neither stops nor reconfigures the meeting recording.
///
/// - Every block is stamped with the host time of its first sample (from the tap's
///   `AVAudioTime`), so the channel can be placed on the meeting clock.
/// - A device change (AirPods connecting, a USB mic unplugged) posts
///   `AVAudioEngineConfigurationChange`; the engine is rebuilt on the new default input.
///   The gap is filled with silence downstream by the timeline aligner.
/// - A 0 Hz input format (no device, or the mic permission denied) is never installed —
///   AVAudioEngine would crash on it — and the rebuild is retried.
final class MicCapture: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noInput
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone is available."
            case .permissionDenied: "Fluence is not allowed to use the microphone."
            }
        }
    }

    private let queue = DispatchQueue(label: "fluence.meeting.mic")
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var onAudio: (@Sendable (CapturedAudio) -> Void)?
    private var onFailure: (@Sendable (Error) -> Void)?
    private var isRunning = false
    private var restartAttempts = 0

    /// Starts capturing. `onAudio` is called on the audio thread.
    func start(
        onAudio: @escaping @Sendable (CapturedAudio) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Failure.permissionDenied }
        try queue.sync {
            guard !isRunning else { return }
            self.onAudio = onAudio
            self.onFailure = onFailure
            try startEngine()
            isRunning = true
        }
    }

    func stop() {
        queue.sync {
            isRunning = false
            tearDown()
            onAudio = nil
            onFailure = nil
        }
    }

    // MARK: - Engine (on `queue`)

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let converter = PCMConverter(from: format) else {
            throw Failure.noInput
        }

        let deliver = onAudio
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, when in
            let samples = converter.convert(buffer)
            guard !samples.isEmpty else { return }
            let duration = Double(buffer.frameLength) / format.sampleRate
            let hostTime = when.isHostTimeValid
                ? when.hostTime
                : MeetingAudioFormat.hostTime(MeetingAudioFormat.now, minus: duration)
            deliver?(CapturedAudio(samples: samples, hostTime: hostTime, source: .microphone))
        }

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in self?.restart() }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            throw error
        }
        self.engine = engine
        restartAttempts = 0
        Log.audio.info("meeting mic started — \(format.sampleRate)Hz × \(format.channelCount)")
    }

    private func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// After a route change: wait for the new device to settle, then rebuild. Retries for
    /// about ten seconds before giving up (a USB mic unplugged with no fallback device).
    private func restart() {
        guard isRunning else { return }
        tearDown()
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isRunning else { return }
            do {
                try self.startEngine()
                Log.audio.info("meeting mic rebuilt after a device change")
            } catch {
                self.restartAttempts += 1
                if self.restartAttempts < 25 {
                    self.restart()
                } else {
                    Log.audio.error("meeting mic could not restart: \(error.localizedDescription, privacy: .public)")
                    self.onFailure?(error)
                }
            }
        }
    }
}
