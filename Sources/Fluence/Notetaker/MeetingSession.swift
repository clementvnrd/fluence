import CryptoKit
import FluenceCore
import Foundation
import FluenceDictionary
import Synchronization

/// One recording in progress: the two captures, their pipelines and spools, the live
/// segments, and the system-audio watchdog. Owned by `MeetingController`.
@MainActor
final class MeetingSession {
    let meetingID: UUID
    let app: MeetingApp?
    let directory: URL
    let key: SymmetricKey
    let speechClock = SpeechClock()
    /// The loudest buffer heard on either channel since the meters last looked (FLU-23).
    let inputLevel = InputLevelBox()
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

    // Watchdog (FLU-32: backoff, no cap), counted within one stretch of silence.
    private var lastRebuild: TimeInterval?
    private var rebuilds = 0
    private var warnedPermission = false
    /// Audio blocks the bounded queues had to drop since the ticker last asked.
    private let dropped: DroppedBlocks
    /// Utterances the engine failed on (FLU-54), saved with the meeting.
    private let failedUtterances = UntranscribedLog()

    var hasSystemAudio: Bool { tap != nil }
    /// Speech not transcribed so far; after `finish()`, what the retry at the end could not
    /// recover either (FLU-54).
    var untranscribed: [UntranscribedSpan] { failedUtterances.all }
    var systemSpoolURL: URL? { systemPipeline == nil ? nil : MeetingAudioSpool.url(in: directory, source: .system) }
    var elapsed: TimeInterval { MeetingAudioFormat.seconds(from: startHost, to: MeetingAudioFormat.now) }

    static func markerURL(in directory: URL) -> URL {
        directory.appendingPathComponent("recording.marker")
    }

    /// How many times recovery has tried this meeting (FLU-32), beside the marker.
    static func recoveryAttemptsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("recovery.attempts")
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
        let dropped = DroppedBlocks()
        self.dropped = dropped
        let tap = SystemAudioTap(app: app)
        do {
            try tap.start { dropped.note(systemContinuation.yield($0)) }
            self.tap = tap
        } catch {
            Log.audio.error("system audio unavailable: \(error.localizedDescription, privacy: .public)")
            self.tap = nil
        }

        let clock = speechClock
        let failedUtterances = failedUtterances
        let callbacks = ChannelPipeline.Callbacks(
            segment: { segment in Task { @MainActor in onSegment(segment) } },
            speech: { _, time in clock.heard(at: time) },
            untranscribed: { span in failedUtterances.add(span) }
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

        // The level is measured here rather than in the capture callbacks: those run on the
        // real-time audio thread, where a lock has no place.
        let micPipeline = micPipeline
        let levels = inputLevel
        consumers.append(Task.detached(priority: .userInitiated) {
            for await audio in micStream {
                levels.record(AudioLevel.level(audio.samples))
                await micPipeline.consume(audio)
            }
        })
        if let systemPipeline {
            consumers.append(Task.detached(priority: .userInitiated) {
                for await audio in systemStream {
                    levels.record(AudioLevel.level(audio.samples))
                    await systemPipeline.consume(audio)
                }
            })
        }

        do {
            try mic.start(
                onAudio: { dropped.note(micContinuation.yield($0)) },
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

    enum WatchdogReport: Equatable {
        case quiet
        /// Something to tell the user.
        case warn(String)
        /// The call's sound is back: a watchdog message can go.
        case recovered
    }

    /// Called once a second. Rebuilds a tap that went silent while the app is playing (a
    /// sample-rate change or AirPods sleeping can do that), on `TapWatchdog`'s backoff and
    /// for as long as the silence lasts; a tap that never carried anything while the app
    /// plays almost always means the permission was denied.
    func checkSystemAudio() -> WatchdogReport {
        guard let tap else { return .quiet }
        let status = tap.signalStatus()
        guard status.secondsSinceSignal >= TapWatchdog.silenceThreshold, tap.isSourcePlaying() else {
            guard rebuilds > 0, status.secondsSinceSignal < TapWatchdog.silenceThreshold else { return .quiet }
            rebuilds = 0
            lastRebuild = nil
            Log.audio.info("system tap carries sound again")
            return .recovered
        }
        let sinceLast = lastRebuild.map { elapsed - $0 }
        guard TapWatchdog.isRebuildDue(silentFor: status.secondsSinceSignal, sinceLastRebuild: sinceLast, rebuilds: rebuilds) else {
            return .quiet
        }
        rebuildTap()

        if !status.everHadSignal {
            guard !warnedPermission else { return .quiet }
            warnedPermission = true
            return .warn("Fluence n'entend rien de l'appel. Autorisez-le dans Réglages Système › Confidentialité et sécurité › "
                + "Enregistrement de l'écran et de l'audio système (Enregistrement audio du système uniquement), puis relancez l'enregistrement.")
        }
        // The first rebuild usually works unnoticed; say so only when it did not.
        return rebuilds >= 2 ? .warn(TapWatchdog.notice(nextTryIn: TapWatchdog.delay(afterRebuilds: rebuilds))) : .quiet
    }

    /// Audio blocks dropped since the last call (never their content).
    func takeDroppedBlocks() -> Int {
        dropped.take()
    }

    private func rebuildTap() {
        lastRebuild = elapsed
        rebuilds += 1
        tap?.stop()
        let replacement = SystemAudioTap(app: app)
        let continuation = systemContinuation
        let dropped = dropped
        do {
            try replacement.start { dropped.note(continuation.yield($0)) }
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

    /// Stops both captures and drains the pipelines: every utterance is transcribed (or
    /// tried twice and listed in `untranscribed`, FLU-54) and the spools are closed when
    /// this returns.
    func finish() async {
        mic.stop()
        tap?.stop()
        micContinuation.finish()
        systemContinuation.finish()
        for consumer in consumers { await consumer.value }
        let micOutcome = await micPipeline.finish()
        micSegments = micOutcome.segments
        var missing = micOutcome.untranscribed
        if let systemPipeline {
            let systemOutcome = await systemPipeline.finish()
            systemSegments = systemOutcome.segments
            missing += systemOutcome.untranscribed
        }
        failedUtterances.replace(with: missing)
    }
}

/// Utterances the engine failed on, written from the pipelines' executors and read on the
/// main actor by the autosave (FLU-54). Times only, never audio or text.
final class UntranscribedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [UntranscribedSpan] = []

    var all: [UntranscribedSpan] {
        lock.lock()
        defer { lock.unlock() }
        return spans
    }

    func add(_ span: UntranscribedSpan) {
        lock.lock()
        spans.append(span)
        lock.unlock()
    }

    func replace(with spans: [UntranscribedSpan]) {
        lock.lock()
        self.spans = spans
        lock.unlock()
    }
}

/// Counts audio blocks a full queue dropped. Written from the capture callbacks, so it is
/// a lock-free atomic rather than a lock.
final class DroppedBlocks: Sendable {
    private let count = Atomic<Int>(0)

    func note(_ result: AsyncStream<CapturedAudio>.Continuation.YieldResult) {
        if case .dropped = result { count.add(1, ordering: .relaxed) }
    }

    func take() -> Int {
        count.exchange(0, ordering: .relaxed)
    }
}
