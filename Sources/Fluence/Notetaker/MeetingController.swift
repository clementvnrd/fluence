import AppKit
import CryptoKit
import FluenceCore
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

    /// Someone spoke in the last moments, on either channel: colours the level bars.
    private(set) var isHearingSpeech = false

    /// What the microphone and the call's audio actually sound like, 0…1, smoothed for the
    /// bars in the pill and the banner (FLU-23): flat in silence, up when someone speaks.
    private(set) var inputLevel: Float = 0
    @ObservationIgnored private var levelFollower = LevelFollower()

    /// The recording panel shows the controls and the live transcript (mock-up 07, step 3)
    /// instead of the compact pill (step 2).
    var isPanelExpanded = false {
        didSet { if isPanelExpanded != oldValue { recordingPanel?.relayout() } }
    }

    /// "Zoom", "Google Chrome"… for the banner and the panel.
    var appName: String? { meeting?.appBundleID.flatMap { MeetingApps.identify($0)?.name } }

    /// The people in the call, the user included, when the calendar or the call's window
    /// says who they are.
    var participantCount: Int? {
        let others = max(meeting?.attendees.count ?? 0, session?.participants.count ?? 0)
        return others > 0 ? others + 1 : nil
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
            fail("Fluence a besoin d'accéder au micro pour prendre des notes de réunion. Autorisez-le dans Réglages Système › Confidentialité et sécurité › Micro.")
            return
        }

        _ = await CalendarContext.shared.requestAccessIfNeeded()
        let calendar = CalendarContext.shared.currentMeeting()

        var meeting = Meeting(
            title: calendar?.title ?? detected.map { "Appel \($0.service)" } ?? "Réunion",
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
                notice = "Seul votre micro est enregistré : Fluence n'a pas pu capter l'audio de l'appel."
            }
            try MeetingStore.shared.save(meeting)
        } catch {
            session = nil
            fail("Impossible de lancer l'enregistrement : \(error.localizedDescription)")
            return
        }

        self.meeting = meeting
        liveSegments = []
        elapsed = 0
        detector.keepPollingWhileRecording = true
        showRecordingPanel()
        if !pendingDownloads.isEmpty {
            notice = "Téléchargement des modèles locaux depuis Hugging Face (une seule fois) : " + pendingDownloads.joined(separator: ", ") + "."
        }
        Log.app.info("meeting recording started (\(meeting.trigger.rawValue, privacy: .public))")
        runTicker()
        runLevelMeter()
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

    /// About 30 times a second, while recording: the loudest buffer since the last look,
    /// through the meter's rise and fall.
    private func runLevelMeter() {
        levelFollower.reset()
        inputLevel = 0
        Task { [weak self] in
            let interval = 1.0 / 30
            while let self, self.state == .recording, let session = self.session {
                try? await Task.sleep(for: .seconds(interval))
                guard self.state == .recording, self.session === session else { break }
                let level = self.levelFollower.update(target: session.inputLevel.take(), dt: interval)
                // Only publish visible changes: the pill redraws on each one.
                if abs(level - self.inputLevel) > 0.01 || (level == 0 && self.inputLevel != 0) {
                    self.inputLevel = level
                }
            }
            self?.inputLevel = 0
        }
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
                let hearing = session.speechClock.last.map { session.elapsed - $0 < 2 } ?? false
                if hearing != self.isHearingSpeech { self.isHearingSpeech = hearing }

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
        isHearingSpeech = false
        inputLevel = 0
        isPanelExpanded = false
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

    // MARK: - Development preview

    /// Screenshots of a fresh install (FLU-11): only with `FLUENCE_SUPPORT_DIRECTORY` set (a
    /// scratch folder, see `AppPaths`) and `FLUENCE_PREVIEW_RECORDING_PANEL=1`, shows the
    /// recording panel with no session — no microphone opened, no meeting created, and its
    /// Arrêter key does nothing.
    ///
    /// FLU-12: `FLUENCE_PREVIEW_RECORDING_PANEL=expanded` opens the panel expanded, and
    /// `FLUENCE_PREVIEW_MEETING_FILE` names a JSON `Meeting` (synthetic, in the scratch
    /// folder) whose title, app and segments stand in for a live one. `=detected` shows the
    /// detection card instead.
    func previewRecordingPanelIfRequested() {
        guard AppPaths.override != nil, state == .idle,
              let mode = ProcessInfo.processInfo.environment["FLUENCE_PREVIEW_RECORDING_PANEL"]
        else { return }
        if mode == "detected" {
            let app = MeetingApps.native[0]
            state = .detected(DetectedMeeting(app: app, service: app.name, pid: nil))
            countdown = 8
            showDetectionPanel()
            return
        }
        state = .recording
        elapsed = 767
        isHearingSpeech = true
        inputLevel = 0.55
        if let path = ProcessInfo.processInfo.environment["FLUENCE_PREVIEW_MEETING_FILE"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let preview = try? decoder.decode(Meeting.self, from: data) {
                meeting = preview
                liveSegments = preview.segments
            }
        }
        isPanelExpanded = mode == "expanded"
        showRecordingPanel()
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

    /// The live transcript, in the expanded recording panel. Shown on request only, and the
    /// panel is excluded from screen sharing.
    func showLiveTranscript() {
        guard isRecording else { return }
        isPanelExpanded = true
        showRecordingPanel()
    }
}

/// The loudest level heard since the last `take()`, written by the audio consumers, read by
/// the level meter.
final class InputLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func record(_ level: Float) {
        lock.lock()
        peak = max(peak, level)
        lock.unlock()
    }

    /// The peak since the last call, then back to zero: silence reads as 0.
    func take() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let value = peak
        peak = 0
        return value
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
