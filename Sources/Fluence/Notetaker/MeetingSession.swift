import CryptoKit
import Foundation
import MurmurDictionary

/// One recording in progress: the two captures, their pipelines and spools, the live
/// segments, and the system-audio watchdog. Owned by `MeetingController`.
@MainActor
final class MeetingSession {
    let meetingID: UUID
    let app: MeetingApp?
    let directory: URL
    let key: SymmetricKey
    let speechClock = SpeechClock()
    /// Meeting time the app was last seen on the mic (call-ended rule).
    var appLastOnMic: TimeInterval = 0
    /// Remote display names read from the meeting window so far, cleaned.
    private(set) var participants: [String] = []

    private let appPID: pid_t?
    private let userNames: [String]
    private let startHost: UInt64
    private let mic = MicCapture()
    private var tap: SystemAudioTap?
    private let micPipeline: ChannelPipeline
    private let systemPipeline: ChannelPipeline?
    private let micContinuation: AsyncStream<CapturedAudio>.Continuation
    private let systemContinuation: AsyncStream<CapturedAudio>.Continuation
    private var consumers: [Task<Void, Never>] = []

    private var micSegments: [TranscriptSegment] = []
    private var systemSegments: [TranscriptSegment] = []
    private var hiddenEchoes: Set<UUID> = []

    // Watchdog.
    private var lastRebuild: TimeInterval = 0
    private var rebuilds = 0
    private var warnedPermission = false

    var hasSystemAudio: Bool { tap != nil }
    var systemSpoolURL: URL? { systemPipeline == nil ? nil : MeetingAudioSpool.url(in: directory, source: .system) }
    var elapsed: TimeInterval { MeetingAudioFormat.seconds(from: startHost, to: MeetingAudioFormat.now) }

    static func markerURL(in directory: URL) -> URL {
        directory.appendingPathComponent("recording.marker")
    }

    init(
        meeting: Meeting,
        app: MeetingApp?,
        appPID: pid_t?,
        userNames: [String],
        corrector: DictionaryCorrector,
        onSegment: @escaping @MainActor @Sendable (TranscriptSegment) -> Void,
        onFailure: @escaping @MainActor @Sendable (StopReason) -> Void
    ) throws {
        meetingID = meeting.id
        self.app = app
        self.appPID = appPID
        self.userNames = userNames
        key = try MeetingStore.shared.meetingKey(for: meeting.id, create: true)
        directory = MeetingStore.shared.directory(for: meeting.id)
        // Marks the meeting as in progress until the final pass completes (crash recovery).
        FileManager.default.createFile(atPath: Self.markerURL(in: directory).path, contents: nil)

        let micSpool = try MeetingAudioSpool(url: MeetingAudioSpool.url(in: directory, source: .microphone), key: key)
        let (micStream, micContinuation) = AsyncStream.makeStream(of: CapturedAudio.self, bufferingPolicy: .bufferingNewest(10_000))
        let (systemStream, systemContinuation) = AsyncStream.makeStream(of: CapturedAudio.self, bufferingPolicy: .bufferingNewest(10_000))
        self.micContinuation = micContinuation
        self.systemContinuation = systemContinuation

        startHost = MeetingAudioFormat.now

        // The system side first: whether it exists decides the mic's echo stage.
        let tap = SystemAudioTap(app: app)
        do {
            try tap.start { systemContinuation.yield($0) }
            self.tap = tap
        } catch {
            Log.audio.error("system audio unavailable: \(error.localizedDescription, privacy: .public)")
            self.tap = nil
        }

        let clock = speechClock
        let callbacks = ChannelPipeline.Callbacks(
            segment: { segment in Task { @MainActor in onSegment(segment) } },
            speech: { _, time in clock.heard(at: time) }
        )
        let reference = self.tap == nil ? nil : ReferenceBuffer()
        if self.tap != nil {
            let systemSpool = try MeetingAudioSpool(url: MeetingAudioSpool.url(in: directory, source: .system), key: key)
            systemPipeline = ChannelPipeline(
                source: .system, meetingStart: startHost, spool: systemSpool, reference: reference,
                hasSystemChannel: true, corrector: corrector, callbacks: callbacks
            )
        } else {
            systemPipeline = nil
        }
        micPipeline = ChannelPipeline(
            source: .microphone, meetingStart: startHost, spool: micSpool, reference: reference,
            hasSystemChannel: self.tap != nil, corrector: corrector, callbacks: callbacks
        )

        let micPipeline = micPipeline
        consumers.append(Task.detached(priority: .userInitiated) {
            for await audio in micStream { await micPipeline.consume(audio) }
        })
        if let systemPipeline {
            consumers.append(Task.detached(priority: .userInitiated) {
                for await audio in systemStream { await systemPipeline.consume(audio) }
            })
        }

        do {
            try mic.start(
                onAudio: { micContinuation.yield($0) },
                onFailure: { _ in Task { @MainActor in onFailure(.captureFailed) } }
            )
        } catch {
            self.tap?.stop()
            micContinuation.finish()
            systemContinuation.finish()
            try? FileManager.default.removeItem(at: Self.markerURL(in: directory))
            throw error
        }
    }

    // MARK: - Live transcript

    func add(_ segment: TranscriptSegment) {
        switch segment.source {
        case .microphone:
            micSegments.append(segment)
            if TranscriptMerger.isEcho(segment, system: systemSegments(near: segment)) {
                hiddenEchoes.insert(segment.id)
            }
        case .system:
            systemSegments.append(segment)
            // A remote segment can arrive after the mic's echo of it.
            for mic in micSegments where !hiddenEchoes.contains(mic.id)
                && abs(mic.start - segment.start) < 30
                && TranscriptMerger.isEcho(mic, system: systemSegments(near: mic)) {
                hiddenEchoes.insert(mic.id)
            }
        }
    }

    private func systemSegments(near segment: TranscriptSegment) -> [TranscriptSegment] {
        systemSegments.filter { $0.end >= segment.start - 30 && $0.start <= segment.end + 30 }
    }

    /// Both channels, time-ordered, echoes included (the final pass decides).
    var allSegments: [TranscriptSegment] {
        TranscriptMerger.sorted(micSegments + systemSegments)
    }

    /// What the live window shows: echoes of the remote side hidden.
    var visibleSegments: [TranscriptSegment] {
        TranscriptMerger.sorted(micSegments.filter { !hiddenEchoes.contains($0.id) } + systemSegments)
    }

    // MARK: - Watchdog

    /// Called once a second. Rebuilds a tap that went silent while the app is playing (a
    /// sample-rate change or AirPods sleeping can do that); a tap that never carried
    /// anything while the app plays almost always means the permission was denied.
    /// Returns a message for the user, if any.
    func checkSystemAudio() -> String? {
        guard let tap else { return nil }
        let status = tap.signalStatus()
        guard status.secondsSinceSignal >= 5, tap.isSourcePlaying() else { return nil }

        if !status.everHadSignal {
            guard !warnedPermission else { return nil }
            warnedPermission = true
            rebuildTap()
            return "Fluence n'entend rien de l'appel. Autorisez-le dans Réglages Système › Confidentialité et sécurité › "
                + "Enregistrement de l'écran et de l'audio système (Enregistrement audio du système uniquement), puis relancez l'enregistrement."
        }
        guard elapsed - lastRebuild >= 15, rebuilds < 20 else { return nil }
        rebuildTap()
        return nil
    }

    private func rebuildTap() {
        lastRebuild = elapsed
        rebuilds += 1
        tap?.stop()
        let replacement = SystemAudioTap(app: app)
        let continuation = systemContinuation
        do {
            try replacement.start { continuation.yield($0) }
            tap = replacement
            Log.audio.info("system tap rebuilt")
        } catch {
            Log.audio.error("system tap rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Participants

    func readParticipants() {
        guard let pid = appPID ?? app.flatMap(MeetingWindowReader.mainPID) else { return }
        let names = ParticipantNames.clean(MeetingWindowReader.participantCandidates(pid: pid), excluding: userNames)
        for name in names where !participants.contains(name) {
            participants.append(name)
        }
    }

    // MARK: - End

    /// Stops both captures and drains the pipelines: every utterance is transcribed and
    /// the spools are closed when this returns.
    func finish() async {
        mic.stop()
        tap?.stop()
        micContinuation.finish()
        systemContinuation.finish()
        for consumer in consumers { await consumer.value }
        micSegments = await micPipeline.finish()
        if let systemPipeline { systemSegments = await systemPipeline.finish() }
    }
}
