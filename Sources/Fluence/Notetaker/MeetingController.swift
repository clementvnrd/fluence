import AppKit
import CryptoKit
import FluenceCore
import Foundation
import IOKit.pwr_mgt
import Observation

/// Orchestrates the Notetaker's capture half: detection → card → recording → final pass.
///
/// ```
/// idle ──detected──► detected ──Record (click)──► recording ──stop──► processing ──► idle
///   ▲                   │ Not this time                                              │
///   └───────────────────┘◄──────────────────────── failed (dismissable) ◄────────────┘
/// ```
///
/// Records only after a click (FLU-34): *Enregistrer* on the card, or *Prendre des notes*.
/// A card left alone records nothing, unless the user chose a delay in Settings
/// (*Enregistrer sans clic*) — then the card shows it counting down (`DetectionOffer`).
/// While recording, the menu bar icon changes and a small panel with a lit record lamp and
/// the elapsed time stays on screen.
///
/// Recording stops on: Stop, the meeting app releasing the mic for 30 s (call ended),
/// 10 minutes of silence on both channels, `maxDurationMinutes`, the Mac going to sleep or
/// another user taking it. A locked or dark screen keeps recording, and idle sleep is held
/// off while a meeting records (FLU-32). The meeting is saved every 10 s while recording,
/// and a meeting found still marked as recording at launch (a crash, a failed save) is
/// finalised from its spool, at most twice (`RecoveryPlan`).
///
/// The final pass of one meeting runs beside the next: a call starting while the last one
/// is processed is offered and recorded (FLU-32).
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
    /// The delay `countdown` started from, for the card's ring.
    private(set) var countdownTotal: Int?
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
    /// Recording, or a final pass still running (possibly behind a new recording).
    var isBusy: Bool { state == .recording || state == .processing || finalizing > 0 }

    /// Final passes in flight. Observed: the updater must not relaunch during one.
    private(set) var finalizing = 0
    /// The same passes, by meeting, so quitting can wait for them (FLU-54).
    @ObservationIgnored
    private var finalPasses: [UUID: Task<Void, Never>] = [:]

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
    /// Holds off idle sleep while recording (FLU-32); 0 when none is held.
    @ObservationIgnored
    private var sleepAssertion = IOPMAssertionID(0)

    // MARK: - Launch

    /// Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        detector.onDetected = { [weak self] detected in self?.offer(detected) ?? false }
        detector.start()
        observeLockAndSleep()
        observeVoicePrintSetting()
        VoicePrintStore.shared.removeCandidates()
        Task { await recoverInterruptedMeetings() }
    }

    // MARK: - Detection card

    /// Shows the card unless a meeting is recording or already offered. A meeting still
    /// being processed does not block it (FLU-32: back-to-back calls).
    private func offer(_ detected: DetectedMeeting) -> Bool {
        guard state == .idle || state == .processing || isFailed else { return false }
        state = .detected(detected)
        let initial = DetectionOffer(autoRecordSeconds: NotetakerSettings.shared.autoRecordSeconds)
        countdown = initial.remaining
        countdownTotal = initial.total
        showDetectionPanel()

        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            var offer = initial
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, case .detected = self.state else { return }
                switch offer.tick(callOngoing: self.detector.isOnMicrophone(detected.app)) {
                case .wait:
                    self.countdown = offer.remaining
                case .record:
                    self.countdown = 0
                    self.record(detected, trigger: .detected)
                    return
                case .withdraw:
                    // The call ended before anyone answered the card.
                    self.dismissDetection()
                    return
                }
            }
        }
        return true
    }

    /// "Enregistrer" on the card.
    func acceptDetection() {
        guard case .detected(let detected) = state else { return }
        record(detected, trigger: .detected)
    }

    /// "Pas cette fois" on the card. The app is not offered again until it releases the mic.
    func dismissDetection() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        countdownTotal = nil
        detectionPanel?.dismiss()
        if case .detected = state { state = finalizing > 0 ? .processing : .idle }
    }

    func dismissFailure() {
        if isFailed { state = finalizing > 0 ? .processing : .idle }
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
        case .idle, .failed, .processing:
            let app = detector.appsOnMicrophone.lazy.compactMap(MeetingApps.identify).first
            let detected = app.map { DetectedMeeting(app: $0, service: $0.name, pid: MeetingWindowReader.mainPID(for: $0)) }
            if let app { detector.markOffered(app) }
            Task { await begin(detected, trigger: .manual) }
        case .recording:
            break
        }
    }

    private func record(_ detected: DetectedMeeting, trigger: MeetingTrigger) {
        dismissDetection()
        Task { await begin(detected, trigger: trigger) }
    }

    private func begin(_ detected: DetectedMeeting?, trigger: MeetingTrigger) async {
        guard state != .recording else { return }
        state = .recording
        notice = nil
        lastStopReason = nil

        guard await Permissions.requestMicrophone() else {
            fail("Fluence a besoin d'accéder au micro pour prendre des notes de réunion. Autorisez-le dans Réglages Système › Confidentialité et sécurité › Micro.")
            return
        }

        _ = await CalendarContext.shared.requestAccessIfNeeded()
        // FLU-33: the event on the app the call is in, not merely the latest one.
        let service = detected.flatMap { MeetingApps.callService(app: $0.app, service: $0.service) }
        let calendar = CalendarContext.shared.currentMeeting(service: service)

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
                onSegment: { [weak self, id = meeting.id] segment in self?.appendLive(segment, meetingID: id) },
                onFailure: { [weak self, id = meeting.id] reason in
                    // A failure from a meeting already stopped must not stop the next one.
                    if self?.session?.meetingID == id { self?.stop(reason: reason) }
                }
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
        holdOffIdleSleep()
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
        Diagnostics.error("meeting.failed")
    }

    // MARK: - While recording

    private func appendLive(_ segment: TranscriptSegment, meetingID: UUID) {
        // Late segments of a meeting being finalised come back through `finish()`.
        guard let session, session.meetingID == meetingID, meeting != nil else { return }
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

                switch session.checkSystemAudio() {
                case .quiet: break
                case .warn(let message): self.notice = message
                case .recovered: if self.notice?.hasPrefix("Le son de l'appel est coupé") == true { self.notice = nil }
                }
                let dropped = session.takeDroppedBlocks()
                if let message = DroppedAudio.notice(blocks: dropped) {
                    Log.audio.error("meeting audio: \(dropped) blocks dropped, transcription behind")
                    Diagnostics.error("meeting.audio.dropped")
                    self.notice = message
                }
                if tick % 10 == 0 { self.autosave() }
                if tick % 20 == 5, NotetakerSettings.shared.readNamesFromMeetingWindow { session.readParticipants() }
            }
        }
    }

    private func autosave() {
        guard var meeting else { return }
        meeting.keepAudio = keepAudio
        // FLU-54: what the engine failed on so far, so a crash does not lose its place.
        if let session { meeting.untranscribed = TranscriptionRetry.remaining(session.untranscribed) }
        do {
            try MeetingStore.shared.save(meeting)
        } catch {
            Log.app.error("meeting autosave failed: \(error.localizedDescription, privacy: .public)")
            Diagnostics.error("meeting.autosave", error)
        }
    }

    // MARK: - Stopping

    /// Stops recording and runs the final pass. Safe to call more than once.
    func stop(reason: StopReason = .user) {
        guard state == .recording, let session, var meeting else { return }
        state = .processing
        finalizing += 1
        lastStopReason = reason
        releaseIdleSleep()
        if StopPolicy.offersAgain(after: reason), let app = session.app {
            detector.allowOfferAgain(app)
        }
        isHearingSpeech = false
        inputLevel = 0
        isPanelExpanded = false
        recordingPanel?.dismiss()
        detector.keepPollingWhileRecording = false
        Log.app.info("meeting recording stopped: \(reason.rawValue, privacy: .public)")

        let id = meeting.id
        finalPasses[id] = Task {
            await session.finish()
            meeting.segments = session.allSegments
            meeting.untranscribed = TranscriptionRetry.remaining(session.untranscribed)
            meeting.endedAt = Date()
            meeting.keepAudio = keepAudio
            // Everything said is on disk from here, before the (longer) final pass: a quit
            // that cannot wait for it loses nothing (FLU-54).
            try? MeetingStore.shared.save(meeting)

            let finalized = await Self.finalPass(
                meeting,
                spool: session.systemSpoolURL,
                micSpool: MeetingAudioSpool.url(in: session.directory, source: .microphone),
                key: session.key,
                windowRoster: session.roster
            )
            let completion = Self.complete(finalized, directory: session.directory)

            // A new meeting may be recording by now: only this one's traces are cleared.
            if self.session === session {
                self.session = nil
                self.meeting = nil
                self.liveSegments = []
                self.notice = nil
            }
            self.finalizing -= 1
            self.finalPasses[id] = nil
            let canTell = self.state == .processing || self.state == .idle
            switch completion {
            case .saveFailed where canTell:
                self.fail("La réunion n'a pas pu être enregistrée. Son audio est gardé sur ce Mac ; Fluence réessaiera au prochain lancement.")
            case .transcriptionPending where canTell:
                self.fail(TranscriptionRetry.notice)
            default:
                if self.state == .processing, self.finalizing == 0 { self.state = .idle }
            }
        }
    }

    // MARK: - Quitting (FLU-54)

    /// Quitting while a meeting records: stop it, take in its last sentences, save, and
    /// wait for the final pass — at most `QuitPlan.maximumWait`. Past that Fluence quits
    /// anyway: the transcript is already saved once the last sentences are in, and the
    /// marker left in place hands the rest to the next launch's recovery.
    func stopForQuit(origin: QuitPlan.Origin) async {
        if state == .recording { stop(reason: .appQuit) }
        let passes = Array(finalPasses.values)
        guard !passes.isEmpty else { return }
        let started = Date()
        let finished = await Self.wait(for: passes, upTo: QuitPlan.maximumWait(for: origin))
        Log.app.info("""
            quit: meeting \(finished ? "finalized" : "left to the next launch", privacy: .public) \
            after \(Int(Date().timeIntervalSince(started)), privacy: .public)s
            """)
    }

    /// Last resort at termination, when no stop could run (FLU-54): saves what the meeting
    /// holds now. Its marker stays, so the next launch finishes it.
    func saveBeforeExit() {
        guard state == .recording else { return }
        autosave()
        Log.app.info("meeting saved at exit, left to the next launch")
    }

    /// Whether every pass finished within `seconds`. The passes themselves are never
    /// cancelled: whatever they did not reach is redone at the next launch.
    private static func wait(for passes: [Task<Void, Never>], upTo seconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            Task {
                for pass in passes { await pass.value }
                once.resume(true)
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(false)
            }
        }
    }

    /// Diarization and naming, off the main actor for the heavy part.
    private static func finalPass(
        _ meeting: Meeting,
        spool: URL?,
        micSpool: URL?,
        key: SymmetricKey?,
        windowRoster: ParticipantRoster
    ) async -> (Meeting, [String: [Float]]) {
        // FLU-33: the mic is diarized only behind the hidden setting, and only if its spool is there.
        let roomSpool = micSpool.flatMap { url in
            NotetakerSettings.shared.diarizeMicrophone && FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let input = MeetingFinalizer.Input(
            meeting: meeting,
            systemSpool: spool,
            key: key,
            corrector: DictionaryStore.shared.corrector,
            windowRoster: windowRoster,
            roomSpool: roomSpool
        )
        let output = await Task.detached(priority: .utility) { await MeetingFinalizer.attribute(input) }.value
        return (MeetingFinalizer.name(output, window: windowRoster), output.voices)
    }

    enum Completion {
        case done
        /// The final save failed: everything is kept for the next launch.
        case saveFailed
        /// Saved, but some speech is still not transcribed: its audio and the marker are
        /// kept, and the notes wait (FLU-54).
        case transcriptionPending
    }

    /// Saves the final meeting; only once it is saved, and every utterance transcribed, are
    /// the spool (unless kept), the marker and the recovery count removed (FLU-32: a failed
    /// save keeps everything; FLU-54: so does speech still untranscribed). Recovery takes
    /// what was kept up at the next launch. `MeetingCompletion` decides.
    @discardableResult
    private static func complete(_ result: (Meeting, [String: [Float]]), directory: URL) -> Completion {
        // The voices are not kept: nothing enrols one yet (FLU-27, see `VoicePrintStore`).
        let (meeting, _) = result
        var saved = true
        do {
            try MeetingStore.shared.save(meeting)
        } catch {
            saved = false
            Log.app.error("final meeting save failed, audio and marker kept: \(error.localizedDescription, privacy: .public)")
            Diagnostics.error("meeting.save.final", error)
        }
        let missing = meeting.untranscribed?.count ?? 0
        let plan = MeetingCompletion.plan(saved: saved, untranscribed: missing, keepAudio: meeting.keepAudio)
        if plan.deleteAudio {
            for source in AudioSource.allCases {
                try? FileManager.default.removeItem(at: MeetingAudioSpool.url(in: directory, source: source))
            }
        }
        if plan.clearMarker {
            try? FileManager.default.removeItem(at: MeetingSession.markerURL(in: directory))
            try? FileManager.default.removeItem(at: MeetingSession.recoveryAttemptsURL(in: directory))
        }
        if plan.announceFinalized {
            NotificationCenter.default.post(name: .meetingFinalized, object: meeting.id)
        }
        guard saved else { return .saveFailed }
        guard missing == 0 else {
            Log.app.error("meeting saved with \(missing) utterances untranscribed; audio and marker kept for the next launch")
            Diagnostics.error("meeting.transcription.pending")
            return .transcriptionPending
        }
        Log.app.info("meeting finalized: \(meeting.segments.count) segments, \(meeting.speakers.count) speakers")
        return .done
    }

    /// FLU-54: the utterances a meeting still lacks, from its spools on disk, at a later
    /// launch. What still fails stays listed.
    private static func transcribeLate(_ meeting: Meeting, directory: URL, key: SymmetricKey) async -> Meeting {
        let spans = TranscriptionRetry.plan(meeting.untranscribed ?? [])
        var readers: [AudioSource: MeetingAudioSpoolReader] = [:]
        for source in AudioSource.allCases {
            readers[source] = try? MeetingAudioSpoolReader(url: MeetingAudioSpool.url(in: directory, source: source), key: key)
        }
        let corrector = DictionaryStore.shared.corrector
        let found = readers
        let outcome = await Task.detached(priority: .utility) {
            await ChannelPipeline.retranscribe(spans, readers: found, corrector: corrector)
        }.value
        var meeting = meeting
        meeting.segments = TranscriptMerger.sorted(meeting.segments + outcome.segments)
        meeting.untranscribed = TranscriptionRetry.remaining(outcome.untranscribed)
        Log.app.info("""
            recovery: \(spans.count - outcome.untranscribed.count, privacy: .public) of \(spans.count, privacy: .public) \
            untranscribed utterances transcribed
            """)
        return meeting
    }

    // MARK: - Crash recovery

    /// A meeting directory still holding a recording marker was interrupted (crash, power
    /// loss, a failed final save): finish it from what was saved and spooled. Each attempt
    /// is counted on disk before it runs; after `RecoveryPlan.maxAttempts` the files stay
    /// as they are and the user is told once.
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
            let attemptsURL = MeetingSession.recoveryAttemptsURL(in: directory)
            let previous = (try? String(contentsOf: attemptsURL, encoding: .utf8))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            switch RecoveryPlan.decide(previousAttempts: previous) {
            case .attempt(let number):
                try? String(number).write(to: attemptsURL, atomically: true, encoding: .utf8)
                Log.app.info("recovering an interrupted meeting, attempt \(number)")
            case .giveUp(let announce):
                guard announce else { continue }
                try? String(RecoveryPlan.announcedCount).write(to: attemptsURL, atomically: true, encoding: .utf8)
                Log.app.error("interrupted meeting left as is after \(RecoveryPlan.maxAttempts) attempts")
                Diagnostics.error("meeting.recovery.gaveUp")
                // FLU-54: a meeting only waiting for sentences the engine never managed gets
                // its notes from what was transcribed.
                if MeetingCompletion.announcesOnGivingUp(untranscribed: meeting.untranscribed?.count ?? 0) {
                    NotificationCenter.default.post(name: .meetingFinalized, object: meeting.id)
                }
                if state == .idle {
                    fail("Une réunion interrompue n'a pas pu être terminée après deux essais. Son audio et sa transcription restent sur ce Mac.")
                }
                continue
            }
            let key = try? MeetingStore.shared.meetingKey(for: id, create: false)
            if let key, meeting.untranscribed?.isEmpty == false {
                meeting = await Self.transcribeLate(meeting, directory: directory, key: key)
            }
            meeting.endedAt = meeting.endedAt
                ?? meeting.startedAt.addingTimeInterval(meeting.segments.map(\.end).max() ?? 0)
            let spool = MeetingAudioSpool.url(in: directory, source: .system)
            let finalized = await Self.finalPass(
                meeting,
                spool: FileManager.default.fileExists(atPath: spool.path) ? spool : nil,
                micSpool: MeetingAudioSpool.url(in: directory, source: .microphone),
                key: key,
                windowRoster: ParticipantRoster()
            )
            if Self.complete(finalized, directory: directory) == .done {
                Log.app.info("recovered an interrupted meeting")
                Diagnostics.recovery("meeting.recovered")
            }
        }
    }

    // MARK: - System events

    private func observeLockAndSleep() {
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handle(.screenLocked) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, SystemEvent)] = [
            (NSWorkspace.screensDidSleepNotification, .displaySlept),
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.sessionDidResignActiveNotification, .userSwitchedOut),
        ]
        for (name, event) in events {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handle(event) }
            })
        }
    }

    private func handle(_ event: SystemEvent) {
        guard state == .recording else { return }
        if let reason = StopPolicy.reason(for: event) {
            stop(reason: reason)
        } else {
            Log.app.info("meeting keeps recording through \(String(describing: event), privacy: .public)")
        }
    }

    /// Only while recording: a call goes on with the screen dark, but the Mac must not
    /// fall asleep under it. Released at stop.
    private func holdOffIdleSleep() {
        guard sleepAssertion == 0 else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Fluence enregistre une réunion" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            sleepAssertion = id
        } else {
            Log.app.error("idle sleep assertion refused: \(result)")
            Diagnostics.error("meeting.sleepAssertion", code: Int(result))
        }
    }

    private func releaseIdleSleep() {
        guard sleepAssertion != 0 else { return }
        IOPMAssertionRelease(sleepAssertion)
        sleepAssertion = 0
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
    /// detection card instead, as it waits for a click; `=countdown` shows it counting down
    /// from 10 s, as with *Enregistrer sans clic* (FLU-34).
    func previewRecordingPanelIfRequested() {
        guard AppPaths.override != nil, state == .idle,
              let mode = ProcessInfo.processInfo.environment["FLUENCE_PREVIEW_RECORDING_PANEL"]
        else { return }
        if mode == "detected" || mode == "countdown" {
            let app = MeetingApps.native[0]
            state = .detected(DetectedMeeting(app: app, service: app.name, pid: nil))
            if mode == "countdown" {
                countdownTotal = 10
                countdown = 8
            }
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

/// Resumes a continuation once, whichever of several racers gets there first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
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
