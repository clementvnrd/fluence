import AppKit
import CryptoKit
import Foundation
import Observation

/// Orchestrates the Notetaker's capture half: detection → card → recording → final pass.
///
/// ```
/// idle ──detected──► detected ──Record / countdown──► recording ──stop──► processing ──► idle
///   ▲                   │ Not now                                                    │
///   └───────────────────┘◄──────────────────────── failed (dismissable) ◄────────────┘
/// ```
///
/// Never records silently: a recording starts from the card (Record, or its visible
/// countdown) or from the menu. While recording, the menu bar icon changes and a small
/// panel with a lit record lamp and the elapsed time stays on screen.
///
/// Recording stops on: Stop, the meeting app releasing the mic for 30 s (call ended),
/// 10 minutes of silence on both channels, `maxDurationMinutes`, screen lock or sleep.
/// The meeting is saved every 30 s while recording, and a meeting found still marked as
/// recording at launch (a crash) is finalised from its spool.
@MainActor
@Observable
final class MeetingController {
    static let shared = MeetingController()

    enum State: Equatable {
        case idle
        case detected(DetectedMeeting)
        case recording
        case processing
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Seconds left on the detection card; `nil` waits for a click.
    private(set) var countdown: Int?
    /// The meeting being recorded, with its live transcript.
    private(set) var meeting: Meeting?
    /// What the live transcript window shows: mic echoes of the remote side hidden.
    private(set) var liveSegments: [TranscriptSegment] = []
    private(set) var elapsed: TimeInterval = 0
    /// A problem worth telling the user while recording (system audio silent, …).
    private(set) var notice: String?
    private(set) var lastStopReason: StopReason?

    /// The per-meeting "keep audio" checkbox (decision FLU-9 #2).
    var keepAudio = false {
        didSet { meeting?.keepAudio = keepAudio }
    }

    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .recording || state == .processing }

    /// Models a first meeting will download from Hugging Face, for the card and panel.
    var pendingDownloads: [String] { MeetingSpeechModels.missingDownloads }

    @ObservationIgnored
    private let detector = MeetingDetector()
    @ObservationIgnored
    private var session: MeetingSession?
    @ObservationIgnored
    private var countdownTask: Task<Void, Never>?
    @ObservationIgnored
    private var started = false
    @ObservationIgnored
    private var observers: [NSObjectProtocol] = []
    @ObservationIgnored
    private var detectionPanel: MeetingDetectionPanel?
    @ObservationIgnored
    private var recordingPanel: MeetingRecordingPanel?
    @ObservationIgnored
    private var transcriptPanel: LiveTranscriptPanel?

    // MARK: - Launch

    /// Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        detector.onDetected = { [weak self] detected in self?.offer(detected) }
        detector.start()
        observeLockAndSleep()
        observeVoicePrintSetting()
        Task { await recoverInterruptedMeetings() }
    }

    // MARK: - Detection card

    private func offer(_ detected: DetectedMeeting) {
        guard state == .idle || isFailed else { return }
        state = .detected(detected)
        let seconds = NotetakerSettings.shared.countdownSeconds
        countdown = seconds > 0 ? seconds : nil
        showDetectionPanel()

        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, case .detected = self.state else { return }
                // The call ended before anyone answered the card.
                if !self.detector.isOnMicrophone(detected.app) {
                    self.dismissDetection()
                    return
                }
                guard let remaining = self.countdown else { continue }
                if remaining <= 1 {
                    self.countdown = 0
                    self.record(detected, trigger: .detected)
                    return
                }
                self.countdown = remaining - 1
            }
        }
    }

    /// "Record" on the card.
    func acceptDetection() {
        guard case .detected(let detected) = state else { return }
        record(detected, trigger: .detected)
    }

    /// "Not now" on the card. The app is not offered again until it releases the mic.
    func dismissDetection() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        detectionPanel?.dismiss()
        if case .detected = state { state = .idle }
    }

    func dismissFailure() {
        if isFailed { state = .idle }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Starting

    /// "Take meeting notes" from the menu: records the meeting app on the mic if there is
    /// one, otherwise everything the Mac plays.
    func takeNotes() {
        switch state {
        case .detected(let detected):
            record(detected, trigger: .detected)
        case .idle, .failed:
            let app = detector.appsOnMicrophone.lazy.compactMap(MeetingApps.identify).first
            let detected = app.map { DetectedMeeting(app: $0, service: $0.name, pid: MeetingWindowReader.mainPID(for: $0)) }
            if let app { detector.markOffered(app) }
            Task { await begin(detected, trigger: .manual) }
        case .recording, .processing:
            break
        }
    }

    private func record(_ detected: DetectedMeeting, trigger: MeetingTrigger) {
        dismissDetection()
        Task { await begin(detected, trigger: trigger) }
    }

    private func begin(_ detected: DetectedMeeting?, trigger: MeetingTrigger) async {
        guard !isBusy else { return }
        state = .recording
        notice = nil
        lastStopReason = nil

        guard await Permissions.requestMicrophone() else {
            fail("Fluence needs microphone access to take meeting notes. Allow it in System Settings › Privacy & Security › Microphone.")
            return
        }

        _ = await CalendarContext.shared.requestAccessIfNeeded()
        let calendar = CalendarContext.shared.currentMeeting()

        var meeting = Meeting(
            title: calendar?.title ?? detected.map { "\($0.service) call" } ?? "Meeting",
            appBundleID: detected?.app.mainBundleID,
            trigger: calendar != nil && trigger == .detected ? .calendar : trigger,
            startedAt: Date(),
            attendees: calendar?.attendees ?? [],
            keepAudio: NotetakerSettings.shared.keepAudioByDefault
        )
        meeting.speakers = [.me(), .others]
        keepAudio = meeting.keepAudio

        do {
            let session = try MeetingSession(
                meeting: meeting,
                app: detected?.app,
                appPID: detected?.pid,
                userNames: [NSFullUserName(), calendar?.userName].compactMap { $0 },
                corrector: DictionaryStore.shared.corrector,
                onSegment: { [weak self] segment in self?.appendLive(segment) },
                onFailure: { [weak self] reason in self?.stop(reason: reason) }
            )
            self.session = session
            if !session.hasSystemAudio {
                notice = "Only your microphone is being recorded: Fluence could not capture the call's audio."
            }
            try MeetingStore.shared.save(meeting)
        } catch {
            session = nil
            fail("Could not start recording: \(error.localizedDescription)")
            return
        }

        self.meeting = meeting
        liveSegments = []
        elapsed = 0
        detector.keepPollingWhileRecording = true
        showRecordingPanel()
        if !pendingDownloads.isEmpty {
            notice = "Downloading on-device models from Hugging Face (one time): " + pendingDownloads.joined(separator: ", ") + "."
        }
        Log.app.info("meeting recording started (\(meeting.trigger.rawValue, privacy: .public))")
        runTicker()
    }

    private func fail(_ message: String) {
        state = .failed(message)
        recordingPanel?.dismiss()
        Log.app.error("meeting failed: \(message, privacy: .public)")
    }

    // MARK: - While recording

    private func appendLive(_ segment: TranscriptSegment) {
        guard let session, meeting != nil else { return }
        session.add(segment)
        meeting?.segments = session.allSegments
        liveSegments = session.visibleSegments
    }

    /// Once a second: elapsed time, stop conditions, the tap watchdog, autosave,
    /// participant names.
    private func runTicker() {
        Task { [weak self] in
            var tick = 0
            while let self, self.state == .recording, let session = self.session {
                try? await Task.sleep(for: .seconds(1))
                guard self.state == .recording, self.session === session else { return }
                tick += 1
                self.elapsed = session.elapsed

                if let app = session.app, self.detector.isOnMicrophone(app) {
                    session.appLastOnMic = session.elapsed
                }
                let policy = StopPolicy(maxDuration: Double(NotetakerSettings.shared.maxDurationMinutes) * 60)
                if let reason = policy.reason(
                    elapsed: session.elapsed,
                    lastSpeech: session.speechClock.last,
                    appLastUsingMic: session.app == nil ? nil : session.appLastOnMic
                ) {
                    self.stop(reason: reason)
                    return
                }

                if let message = session.checkSystemAudio() { self.notice = message }
                if tick % 30 == 0 { self.autosave() }
                if tick % 20 == 5, NotetakerSettings.shared.readNamesFromMeetingWindow { session.readParticipants() }
            }
        }
    }

    private func autosave() {
        guard var meeting else { return }
        meeting.keepAudio = keepAudio
        do {
            try MeetingStore.shared.save(meeting)
        } catch {
            Log.app.error("meeting autosave failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Stopping

    /// Stops recording and runs the final pass. Safe to call more than once.
    func stop(reason: StopReason = .user) {
        guard state == .recording, let session, var meeting else { return }
        state = .processing
        lastStopReason = reason
        recordingPanel?.dismiss()
        detector.keepPollingWhileRecording = false
        Log.app.info("meeting recording stopped: \(reason.rawValue, privacy: .public)")

        Task {
            await session.finish()
            meeting.segments = session.allSegments
            meeting.endedAt = Date()
            meeting.keepAudio = keepAudio
            try? MeetingStore.shared.save(meeting)

            let finalized = await Self.finalPass(
                meeting,
                spool: session.systemSpoolURL,
                key: session.key,
                windowParticipants: session.participants
            )
            Self.complete(finalized, directory: session.directory)

            self.session = nil
            self.meeting = nil
            self.liveSegments = []
            self.notice = nil
            if self.state == .processing { self.state = .idle }
        }
    }

    /// Diarization and naming, off the main actor for the heavy part.
    private static func finalPass(
        _ meeting: Meeting,
        spool: URL?,
        key: SymmetricKey?,
        windowParticipants: [String]
    ) async -> (Meeting, [String: [Float]]) {
        let input = MeetingFinalizer.Input(
            meeting: meeting,
            systemSpool: spool,
            key: key,
            corrector: DictionaryStore.shared.corrector
        )
        let output = await Task.detached(priority: .utility) { await MeetingFinalizer.attribute(input) }.value
        return (MeetingFinalizer.name(output, windowParticipants: windowParticipants), output.voices)
    }

    /// Saves the final meeting, drops the spool unless kept, announces it.
    private static func complete(_ result: (Meeting, [String: [Float]]), directory: URL) {
        let (meeting, voices) = result
        VoicePrintStore.shared.rememberCandidates(meetingID: meeting.id, voices: voices)
        do {
            try MeetingStore.shared.save(meeting)
        } catch {
            Log.app.error("final meeting save failed: \(error.localizedDescription, privacy: .public)")
        }
        if !meeting.keepAudio {
            for source in AudioSource.allCases {
                try? FileManager.default.removeItem(at: MeetingAudioSpool.url(in: directory, source: source))
            }
        }
        try? FileManager.default.removeItem(at: MeetingSession.markerURL(in: directory))
        NotificationCenter.default.post(name: .meetingFinalized, object: meeting.id)
        Log.app.info("meeting finalized: \(meeting.segments.count) segments, \(meeting.speakers.count) speakers")
    }

    // MARK: - Crash recovery

    /// A meeting directory still holding a recording marker was interrupted (crash, power
    /// loss): finish it from what was saved and spooled.
    private func recoverInterruptedMeetings() async {
        try? await Task.sleep(for: .seconds(5))
        let root = MeetingStore.shared.root
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for directory in directories {
            guard FileManager.default.fileExists(atPath: MeetingSession.markerURL(in: directory).path),
                  let id = UUID(uuidString: directory.lastPathComponent),
                  session?.meetingID != id,
                  var meeting = try? MeetingStore.shared.load(id)
            else { continue }
            meeting.endedAt = meeting.endedAt
                ?? meeting.startedAt.addingTimeInterval(meeting.segments.map(\.end).max() ?? 0)
            let key = try? MeetingStore.shared.meetingKey(for: id, create: false)
            let spool = MeetingAudioSpool.url(in: directory, source: .system)
            let finalized = await Self.finalPass(
                meeting,
                spool: FileManager.default.fileExists(atPath: spool.path) ? spool : nil,
                key: key,
                windowParticipants: []
            )
            Self.complete(finalized, directory: directory)
            Log.app.info("recovered an interrupted meeting")
        }
    }

    // MARK: - System events

    private func observeLockAndSleep() {
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop(reason: .screenLocked) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop(reason: .systemSleep) }
        })
    }

    /// Turning voice prints off deletes every print (decision FLU-9 #3).
    private func observeVoicePrintSetting() {
        withObservationTracking {
            _ = NotetakerSettings.shared.voicePrintsEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                if !NotetakerSettings.shared.voicePrintsEnabled { VoicePrintStore.shared.deleteAll() }
                self?.observeVoicePrintSetting()
            }
        }
    }

    // MARK: - Panels

    private func showDetectionPanel() {
        if detectionPanel == nil { detectionPanel = MeetingDetectionPanel(controller: self) }
        detectionPanel?.present()
    }

    private func showRecordingPanel() {
        if recordingPanel == nil { recordingPanel = MeetingRecordingPanel(controller: self) }
        recordingPanel?.present()
    }

    /// The read-only live transcript. Opened on request only: it would otherwise appear
    /// in a screen share.
    func showLiveTranscript() {
        if transcriptPanel == nil { transcriptPanel = LiveTranscriptPanel(controller: self) }
        transcriptPanel?.present()
    }
}

/// Speech activity, written from the pipelines' executors, read by the ticker.
final class SpeechClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval?

    var last: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func heard(at time: TimeInterval) {
        lock.lock()
        value = max(value ?? 0, time)
        lock.unlock()
    }
}
