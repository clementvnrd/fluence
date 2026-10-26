import FluenceCore
import FluenceDictionary
import AVFoundation
import AppKit
import Foundation
import Observation
import OSLog

/// A new engine of the kind that runs now (`Settings.activeEngine`).
///
/// Reading the setting per-utterance is what lets the menu's engine picker take effect on
/// the very next hold instead of needing a restart. Main-actor isolated like the setting it
/// reads — it used to be `@Sendable` and *assert* main-actor isolation inside, which traps
/// the moment anything calls it from elsewhere.
@MainActor
func engineForCurrentSetting() -> any TranscriptionEngine {
    // The disk is read again at each key-down: a download that just finished counts at once.
    ParakeetDownload.shared.refresh()
    return newEngine(Settings.shared.activeEngine)
}

/// A new engine of one kind. Parakeet only once its model is on disk (FLU-29): its `start()`
/// would otherwise download 600 MB behind « Parlez maintenant… ».
@MainActor
func newEngine(_ kind: SpeechEngineChoice) -> any TranscriptionEngine {
    switch kind {
    case .apple: AppleSpeechEngine()
    case .whisper: WhisperEngine(
        variant: Settings.shared.whisperModel,
        language: Settings.shared.dictationLanguage.whisperLanguageCode
    )
    case .parakeet: ParakeetEngine()
    }
}

@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        /// No HUD.
        case idle
        /// Mic opening, engine loading.
        case starting
        case listening
        /// After key-up, until the text is typed.
        case finishing
        /// FLU-29: what happened, said on the capsule — an error, « Rien entendu », « Copié »,
        /// « Annulé », a notice. `id` is the message's identity in `CapsuleTimeline`: only its
        /// own timer takes it down, however alike two messages read.
        case message(CapsuleMessage, id: UInt64)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .message: false
            }
        }

        /// The HUD shows messages as well as activity: an error that only reaches the log is
        /// indistinguishable, to the user, from the key doing nothing.
        var showsHUD: Bool {
            switch self {
            case .message: true
            default: isActive
            }
        }
    }

    private(set) var state: State = .idle
    /// Whole text so far, overwritten on each revision; the HUD and the comparison window show it.
    private(set) var transcript = ""
    /// 0…1, smoothed; feeds the waveform and the VU meter.
    private(set) var level: Float = 0
    @ObservationIgnored private var levelFollower = LevelFollower()

    // MARK: FLU-5 input
    /// The dictation in progress keeps recording after the key comes up (double-tap, or
    /// push-to-talk + Space). A tap of the key, or the HUD's Stop key, ends it.
    private(set) var isHandsFree = false
    /// The dictation in progress is a Command Mode instruction: the words are applied to the
    /// selected text instead of being typed.
    private(set) var isCommand = false
    /// What the last dictation typed, for ⌃⌘V / ⌃⌘C. In memory only, never written anywhere,
    /// so it works for the session even when history is set to "Don't keep".
    private(set) var lastTranscript: String?
    // MARK: end FLU-5 input

    /// Clement's HUD and status pill read these names.
    var isCommandMode: Bool { isCommand }
    /// Whether a shortcut is armed (Carbon or the event tap) — the main window's status pill.
    private(set) var isHotkeyActive = false
    /// The engine is still loading a second after key-down — a Parakeet reload after it was
    /// unloaded for idleness, or Core ML's recompile after a macOS update (FLU-31). The HUD
    /// says so; the audio is recorded meanwhile, so nothing waits on it.
    private(set) var isPreparingEngine = false
    /// How long a load may take before the HUD mentions it: a warm reload (0.1–0.4 s) never shows.
    private static let preparingNoticeDelay: Duration = .seconds(1)
    /// The engine the dictation in progress runs on, for the capsule (« Préparation de
    /// Parakeet… », the language pill only for engines that use it).
    private(set) var sessionEngine: SpeechEngineChoice?

    // MARK: FLU-29 — the capsule's messages and the kept recording

    /// When the message on the capsule goes (`CapsuleTimeline`).
    @ObservationIgnored private var timeline = CapsuleTimeline()
    /// A failed dictation's audio, in memory only, for *Réessayer* (`DictationRetry`).
    @ObservationIgnored private var keptRecording: KeptRecording?
    /// Forgets `keptRecording` once its minute is up.
    @ObservationIgnored private var keptRecordingExpiry: Task<Void, Never>?

    /// The comparison whose local engines are running, by group: its card shows a spinner.
    private(set) var runningComparisonGroup: String?
    /// Comparisons still waiting for Wispr Flow's row, by group. The dictation itself has
    /// already ended: a new one can start meanwhile (FLU-48).
    private(set) var groupsWaitingForWispr: Set<String> = []
    var isWaitingForWispr: Bool { !groupsWaitingForWispr.isEmpty }
    /// Release of the last recording Wispr was triggered for: the next one's search for
    /// Wispr's row starts there, so it never takes the previous row for its own.
    @ObservationIgnored private var lastWisprReleasedAt: Date?

    /// The last app other than Fluence to be frontmost: where a dictation started from the
    /// main window's Dicter button is typed (Clement's focus restore).
    @ObservationIgnored private var lastExternalApp: NSRunningApplication?

    private let hotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    private let makeEngine: @MainActor () -> any TranscriptionEngine

    /// Injected only by tests; production picks the cleanup level's formatter per utterance
    /// (`DictationPipeline`), so a change in the menu applies to the very next hold.
    private let formatter: (any TextFormatter)?

    /// The dictation in progress, if any. Its identity is the session token: see
    /// `DictationSession`.
    private var session: DictationSession? {
        // MARK: FLU-5 input — every way a dictation ends passes through here, so the
        // gesture machine and the hands-free / command flags can never outlive it.
        didSet {
            guard session == nil else { return }
            isHandsFree = false
            isCommand = false
            isPreparingEngine = false
            sessionEngine = nil
            hotkey.sessionEnded()
        }
    }

    // How long the mic stays open after the key comes up: see `PostRoll` (FLU-31). People
    // release on the last syllable, not after it — unless they had already stopped talking.

    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        formatter: (any TextFormatter)? = nil,
        makeEngine: @escaping @MainActor () -> any TranscriptionEngine = engineForCurrentSetting
    ) {
        self.formatter = formatter
        self.makeEngine = makeEngine
    }

    // MARK: - Shortcuts

    /// - Returns: `true` once at least one shortcut path is live, Carbon or the event tap, so
    ///   it can be `true` with no Accessibility grant.
    @discardableResult
    func activate() -> Bool {
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.commandKey = Settings.shared.commandModeEnabled ? Settings.shared.commandModeKey : nil
        hotkey.onLanguageToggle = {
            Settings.shared.toggleLanguage()
            if Settings.shared.soundEnabled { NSSound(named: "Tink")?.play() }
        }
        // MARK: FLU-5 input
        hotkey.onGesture = { [weak self] action in self?.handleGesture(action) }
        hotkey.onEscape = { [weak self] in self?.cancelFromEscape() ?? false }
        hotkey.onLastTranscript = Settings.shared.lastTranscriptShortcuts
            ? { [weak self] action in self?.handleLastTranscript(action) }
            : nil
        // The system switched the tap off, so the key-up for the hold in progress may never
        // arrive. Cancel rather than finish: whatever has focus by the time anyone notices
        // is not necessarily where the user meant the text to go. A hands-free dictation
        // waits for no key-up, so it carries on.
        hotkey.onTapDisabled = { [weak self] in
            guard let self, self.session?.source == .hotkey, !self.isHandsFree else { return }
            self.cancelDictation(reason: "the key monitor was interrupted")
        }
        observeSystemEvents()
        let armed = hotkey.start()
        isHotkeyActive = armed
        return armed
    }

    /// Whether the event tap (Accessibility) is armed, not just Carbon.
    var hasEventTap: Bool { hotkey.hasEventTap }

    /// Called when the app quits.
    func deactivate() {
        hotkey.stop()
        cancelDictation(reason: "deactivated")
    }

    /// Re-arms the tap after the user picks a different push-to-talk key, Command Mode
    /// modifier or shortcut setting.
    @discardableResult
    func reloadHotkey() -> Bool {
        // A hold in progress belongs to the old key, whose release the new tap won't report.
        if session?.source == .hotkey {
            cancelDictation(reason: "the push-to-talk key changed")
        }
        hotkey.stop()
        return activate()
    }

    /// A locked screen, a sleeping Mac or a switched user ends any dictation on the spot.
    /// The key-up is lost in all three, and the text would otherwise be typed into whatever
    /// has focus after the user comes back.
    private func observeSystemEvents() {
        guard systemObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        rememberExternalApp(NSWorkspace.shared.frontmostApplication)
        let activation = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.rememberExternalApp(app) }
        }
        systemObservers.append((workspace, activation))
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked")),
        ]
        for (center, name) in events {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.cancelDictation(reason: name.rawValue)
                }
            }
            systemObservers.append((center, observer))
        }
    }

    private func rememberExternalApp(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApp = app
    }

    /// Fluence itself is in front — the Dicter button was clicked in its window. Bring back
    /// the app the user was in, so the text lands there rather than in Fluence.
    private func restoreFocusIfNeeded() async {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier,
              let target = lastExternalApp, !target.isTerminated
        else { return }
        target.activate()
        try? await Task.sleep(for: .milliseconds(250))
    }

    // MARK: - Wispr Flow interop (compare mode on Clement's own builds)

    /// Wispr Flow's key is let go. A no-op in the builds made for other people (FLU-69), which
    /// do not contain the interop at all.
    private func releaseWispr() {
        #if !FLUENCE_WITHOUT_WISPR
        WisprTrigger.release()
        #endif
    }

    /// - Returns: whether Wispr's key was pressed, i.e. whether Wispr hears this recording.
    private func pressWisprInCompareMode() -> Bool {
        #if !FLUENCE_WITHOUT_WISPR
        guard Settings.shared.compareMode else { return false }
        WisprTrigger.press()
        return true
        #else
        return false
        #endif
    }

    // MARK: - Buttons

    /// From a button rather than the hotkey. Wispr's key is pressed too only in compare mode;
    /// for plain dictation that would quietly send every recording to Wispr's cloud.
    func startButtonRecording() {
        guard session == nil else { return }
        let pressedWispr = pressWisprInCompareMode()
        beginDictation(from: .button)
        // Only a recording Wispr heard is worth waiting for (FLU-48).
        session?.pressedWispr = pressedWispr
    }

    /// Stops any dictation, hotkey ones included (the HUD's finish button lands here). Wispr is
    /// let go first so that its upload overlaps our engines' work instead of following it.
    func stopButtonRecording() {
        releaseWispr()
        endDictation(from: nil)
    }

    // MARK: - From key-down to text

    /// Key down. The mic opens *now*, before the engine is ready: whatever is said while the
    /// engine loads waits in the session's stream and reaches the engine first, in order.
    private func beginDictation(from source: DictationSession.Source, command: Bool = false) {
        guard session == nil else { return }

        // A Command Mode instruction is never a comparison: it is applied, not compared.
        let isComparing = Settings.shared.compareMode && !command
        // FLU-29: Parakeet only once its model is whole on disk; Apple until then.
        ParakeetDownload.shared.refresh()
        let kind = Settings.shared.activeEngine
        let session = DictationSession(
            source: source,
            isComparing: isComparing,
            engineName: isComparing ? "Comparaison…" : kind.displayName,
            engineKind: kind
        )
        self.session = session
        sessionEngine = isComparing ? nil : kind
        isCommand = command
        timeline.handle(.dictationStarted, at: Self.uptime)
        state = .starting
        transcript = ""
        level = 0
        levelFollower.reset()

        // Without a grant there's nothing to open yet; `prepare` asks first.
        if Permissions.hasMicrophone {
            guard startCapture(for: session) else { return }
        }

        let limit = Settings.shared.maxRecordingMinutes
        session.limitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit * 60))
            guard !Task.isCancelled, let self, self.session === session, !session.isReleased else { return }
            Log.app.info("dictation reached the \(limit, privacy: .public)-minute limit — finishing")
            self.endDictation(from: nil)
        }

        Task { await prepare(session) }
    }

    /// - Returns: false if capture couldn't start; the session has then already failed.
    private func startCapture(for session: DictationSession) -> Bool {
        let input = session.audioInput
        let trail = session.trail
        do {
            try capture.start(
                deviceUID: Settings.shared.selectedMicrophoneUID,
                onBuffer: { chunk in
                    trail.observe(chunk)
                    input.yield(chunk)
                },
                onLevel: { [weak self] level, duration in
                    Task { @MainActor in self?.updateLevel(level, over: duration) }
                },
                onInterrupted: { [weak self, weak session] reason in
                    Task { @MainActor in self?.captureInterrupted(session, reason: reason) }
                }
            )
        } catch {
            // The system's own text (English, technical) stays in the log.
            Log.audio.error("capture did not start: \(error.localizedDescription)")
            fail(.microphoneDidNotStart)
            return false
        }
        session.captureStarted = true
        if Settings.shared.soundEnabled { NSSound(named: "Tink")?.play() }
        return true
    }

    /// Everything between key-down and "the engine is taking audio". Each `await` can take
    /// seconds — a permission prompt, a cold Parakeet load — so after every one the session
    /// checks it is still the current one, and stands down if not.
    private func prepare(_ session: DictationSession) async {
        if !session.captureStarted {
            guard await Permissions.requestMicrophone() else {
                if self.session === session {
                    fail(.microphoneDenied)
                }
                return
            }
            guard self.session === session else { return }
            // Let go while the permission prompt was up: nothing was recorded.
            guard !session.isReleased else {
                end(session, as: .idle)
                return
            }
            guard startCapture(for: session) else { return }
        }

        let engine = makeEngine()
        session.engine = engine

        let preparingNotice = Task { [weak self] in
            try? await Task.sleep(for: Self.preparingNoticeDelay)
            guard !Task.isCancelled, let self, self.session === session else { return }
            self.isPreparingEngine = true
        }
        defer { preparingNotice.cancel() }

        do {
            let snapshots = try await engine.start()
            preparingNotice.cancel()
            if self.session === session { isPreparingEngine = false }
            guard self.session === session else {
                await engine.cancel()
                return
            }

            // A comparison replays one set of buffers into both engines, so they need a common
            // format: Apple's. `SpeechAnalyzer` crashes the process on anything but 16-bit
            // integer samples, while Parakeet's `feed` copes with int16, int32 and float32.
            let formatOwner: any TranscriptionEngine = session.isComparing ? AppleSpeechEngine() : engine
            guard let format = await formatOwner.preferredInputFormat() else {
                throw TranscriptionError.noAudioFormat
            }
            guard self.session === session else {
                await engine.cancel()
                return
            }

            session.consumeTask = Task { [weak self] in
                do {
                    for try await snapshot in snapshots {
                        guard let self, self.session === session else { return }
                        self.transcript = snapshot.text
                    }
                } catch {
                    self?.engineFailed(session, error)
                }
            }
            session.feedTask = Self.feed(
                session.audio,
                to: engine,
                as: format,
                keepingRecording: session.isComparing
            )
            session.isReady = true

            // Released while the engine was loading: what was said is already buffered, so
            // finish it now rather than throw it away.
            if session.isReleased {
                await complete(session)
            } else {
                state = .listening
            }
        } catch {
            guard self.session === session else { return }
            isPreparingEngine = false
            Log.speech.error("engine did not start: \(error.localizedDescription)")
            Diagnostics.error("dictation.engineStart", error)
            await engine.cancel()
            guard self.session === session else { return }
            // A comparison needs Apple's format to replay into every engine: nothing to fall
            // back on.
            guard !session.isComparing else {
                fail(.engineDidNotStart(.apple, canRetry: false))
                return
            }
            // FLU-29: the microphone keeps recording, into memory only. At release the
            // recording goes to another engine (`DictationRetry`) rather than being lost.
            session.engine = nil
            session.startError = error
            session.feedTask = Self.feed(session.audio, to: nil, as: RecordingReplay.format, keepingRecording: false)
            session.isReady = true
            if session.isReleased {
                await complete(session)
            } else {
                state = .listening
            }
        }
    }

    /// Key up. Capture runs on for the post-roll, then the session completes — now if the
    /// engine is ready, or as soon as `prepare` gets it there.
    private func endDictation(from source: DictationSession.Source?) {
        guard let session, !session.isReleased else { return }
        // The hotkey's release must not stop a recording the Record button started.
        if let source, source != session.source { return }

        releaseWispr()
        session.releasedAt = Date()
        session.releasedHostTime = HostClock.now
        // FLU-31: key-up → text, for Instruments. Ended wherever the session ends.
        let signpostID = Log.signposter.makeSignpostID()
        session.signpostID = signpostID
        session.signpost = Log.signposter.beginInterval("Dictation", id: signpostID)
        // MARK: FLU-5 text — where the text will go, read now while that app is in front.
        session.target = FrontmostApp.capture(readURL: Settings.shared.cleanupLevel.appliesStyle)
        session.limitTask?.cancel()
        state = .finishing
        level = 0
        levelFollower.reset()

        Task { await stopCaptureAfterPostRoll(session) }
        if session.isReady {
            Task { await complete(session) }
        }
    }

    /// Keeps the microphone open until `PostRoll` says the last word is in: at once when the
    /// audio before the release was already room tone, after the full 250 ms otherwise.
    private func stopCaptureAfterPostRoll(_ session: DictationSession) async {
        if session.captureStarted, capture.isRunning, let released = session.releasedHostTime {
            var reason = PostRoll.Reason.elapsed
            while capture.isRunning {
                if case .stop(let why) = PostRoll.decide(session.trail.snapshot, releasedAt: released, now: HostClock.now) {
                    reason = why
                    break
                }
                try? await Task.sleep(for: .seconds(PostRoll.pollInterval))
                // Cancelled meanwhile: the cancel already stopped everything.
                guard self.session === session else { return }
            }
            session.postRollSeconds = HostClock.now - released
            let milliseconds = Int((session.postRollSeconds * 1_000).rounded())
            let why = reason == .trailingSilence ? "silence before release" : "full"
            Log.audio.info("post-roll · \(milliseconds, privacy: .public) ms (\(why, privacy: .public))")
            if session.signpost != nil, let id = session.signpostID {
                Log.signposter.emitEvent("Microphone closed", id: id, "\(milliseconds, privacy: .public) ms after key-up")
            }
        }
        // Cancelled meanwhile: the cancel already stopped everything.
        guard self.session === session else { return }
        capture.stop()
        // Ends the audio stream, which lets the feed task drain the converter and return.
        session.audioInput.finish()
    }

    /// The tail: wait for the last audio to reach the engine, let it finalize, clean up and
    /// type the text.
    private func complete(_ session: DictationSession) async {
        guard let feedTask = session.feedTask else { return }
        let fed = await feedTask.value
        guard self.session === session else { return }

        // Silence or a stray tap never reaches the engine's final pass.
        guard fed.gate == .accepted else {
            Log.speech.info("dictation skipped — \(Self.describe(fed.gate), privacy: .public)")
            await session.engine?.cancel()
            guard self.session === session else { return }
            if session.interruption != nil {
                fail(.microphoneLost)
            } else if fed.gate == .silent {
                // FLU-29: held long enough, nothing above room tone. Said, with the microphone
                // that was listening — the usual cause is the wrong input.
                end(session, showing: .nothingHeard(microphone: Self.microphoneName()))
            } else {
                end(session, as: .idle)
            }
            return
        }

        let engineStarted = HostClock.now
        if session.startError == nil {
            await session.engine?.finish()
            guard self.session === session else { return }
            await session.consumeTask?.value
            guard self.session === session else { return }
        }
        let engineSeconds = HostClock.now - engineStarted
        if session.signpost != nil, let id = session.signpostID {
            Log.signposter.emitEvent("Engine done", id: id)
        }

        if session.isComparing {
            await runComparison(session, recording: fed.recording)
            return
        }

        let raw = transcript
        let heardNothing = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let trigger: DictationRetry.Trigger?
        if session.startError != nil {
            trigger = .didNotStart
        } else if session.engineError != nil, heardNothing || fed.kept != nil {
            // With the recording kept, a failure partway is transcribed again whole rather
            // than typed in part.
            trigger = .failed
        } else if heardNothing {
            // The engine ran and heard no words: as good as silence, said the same way.
            end(session, showing: .nothingHeard(microphone: Self.microphoneName()))
            return
        } else if TranscriptHealth.isDegenerate(raw) {
            // FLU-20: an engine stuck in a loop ("Node.js, Node.js, …") is not what was said.
            // Typing it into the user's document is worse than typing nothing.
            Log.speech.error("dictation dropped — the engine repeated itself (\(raw.count, privacy: .public) characters)")
            Diagnostics.error("dictation.repetitionDropped")
            trigger = .repeated
        } else {
            trigger = nil
        }

        guard let trigger else {
            // Text arrived, but the engine also failed partway and nothing was kept to run
            // again (a very long recording): type what there is, and say so.
            let stoppedEarly = session.engineError != nil
            await deliver(raw, session: session, engineSeconds: engineSeconds)
            // Only over a clean finish: a « Copié » message says more than this one.
            if stoppedEarly, self.session == nil, state == .idle {
                fail(.stoppedEarly(session.engineKind.compared))
            }
            return
        }
        await recover(session, after: trigger, kept: fed.kept, engineSeconds: engineSeconds)
    }

    /// FLU-29: the engine failed on this recording. One automatic retry (`DictationRetry`),
    /// then the capsule's *Réessayer* for a minute, on another engine.
    private func recover(
        _ session: DictationSession,
        after trigger: DictationRetry.Trigger,
        kept chunks: [AudioChunk]?,
        engineSeconds: Double
    ) async {
        let failedEngine = session.engineKind.compared
        // Command Mode instructions are not kept: a retry would apply the rewrite later, to
        // whatever is selected by then.
        guard let chunks, !isCommand else {
            fail(Self.failure(after: trigger, engine: failedEngine, canRetry: false))
            return
        }
        ParakeetDownload.shared.refresh()
        let parakeetReady = ParakeetDownload.shared.isReady
        let whisperReady = WhisperModels.isDownloaded(variant: Settings.shared.whisperModel)
        var lastEngine = failedEngine
        var lastTrigger = trigger
        if let retry = DictationRetry.automatic(
            after: trigger,
            engine: failedEngine,
            attempts: 0,
            parakeetReady: parakeetReady,
            whisperReady: whisperReady
        ) {
            Log.speech.info("dictation · retrying once on \(retry.rawValue, privacy: .public) after \(String(describing: trigger), privacy: .public)")
            Diagnostics.recovery("dictation.retry.automatic")
            transcript = ""
            let result = await replay(chunks, on: SpeechEngineChoice(retry))
            guard self.session === session else { return }
            switch result {
            case .success(let text):
                if TranscriptHealth.isDegenerate(text) {
                    lastTrigger = .repeated
                } else {
                    await deliver(text, session: session, engineSeconds: engineSeconds, engineName: SpeechEngineChoice(retry).displayName)
                    return
                }
            case .failure:
                lastTrigger = .failed
            }
            lastEngine = retry
        }
        keep(KeptRecording(
            chunks: chunks,
            keptAt: Self.uptime,
            failedEngine: lastEngine,
            started: session.started,
            releasedAt: session.releasedAt,
            target: session.target
        ))
        fail(Self.failure(after: lastTrigger, engine: lastEngine, canRetry: true))
    }

    private static func failure(after trigger: DictationRetry.Trigger, engine: ComparedEngine, canRetry: Bool) -> DictationFailure {
        switch trigger {
        case .didNotStart: .engineDidNotStart(engine, canRetry: canRetry)
        case .failed: .engineFailed(engine, canRetry: canRetry)
        case .repeated: .repeated(engine, canRetry: canRetry)
        }
    }

    /// Runs a kept recording through one engine. Empty text counts as a failure here: the
    /// silence gate already heard speech in it.
    private func replay(_ chunks: [AudioChunk], on kind: SpeechEngineChoice) async -> Result<String, Error> {
        let engine = newEngine(kind)
        let variant = Settings.shared.whisperModel
        do {
            let text = try await RecordingReplay.transcribe(chunks, on: engine) {
                // Whisper loads its pipeline lazily; it is on disk (`DictationRetry` never
                // picks an engine that would download).
                if kind == .whisper { try await WhisperModels.shared.prepare(variant: variant) }
            }
            guard !text.isEmpty else { return .failure(TranscriptionError.notRunning) }
            return .success(text)
        } catch {
            Log.speech.error("dictation retry on \(kind.rawValue, privacy: .public) failed: \(error.localizedDescription)")
            Diagnostics.error("dictation.retry.failed", error)
            return .failure(error)
        }
    }

    /// Cleanup, then the text into the app it was meant for — or onto the clipboard, said on
    /// the capsule — then the history.
    private func deliver(
        _ raw: String,
        session: DictationSession,
        engineSeconds: Double,
        engineName: String? = nil
    ) async {
        // MARK: FLU-5 input — Command Mode: the words were an instruction, not text to type.
        if isCommand {
            await runCommand(session, instruction: raw)
            return
        }

        // MARK: FLU-5 text — snippets, cleanup level, language, style, then the dictionary.
        // The dictionary still runs last and regardless of the level: biasing only raises
        // the odds of the right word; that pass guarantees it.
        let processed = await DictationPipeline.process(
            raw,
            category: session.target?.category ?? .other,
            bundleID: session.target?.bundleID == Bundle.main.bundleIdentifier
                ? lastExternalApp?.bundleIdentifier
                : session.target?.bundleID,
            formatter: formatter
        )
        // Cancelled during cleanup (screen locked, say): don't type into whatever has focus now.
        guard self.session === session else { return }
        let output = processed.text
        let corrections = processed.corrections
        if processed.snippetCount > 0 {
            Log.speech.info("snippets · \(processed.snippetCount, privacy: .public) expanded")
        }
        if !corrections.isEmpty {
            Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
        }

        // Typed first, filed second: the user is waiting on the text, not on the history.
        let processSeconds = session.releasedAt.map { Date().timeIntervalSince($0) } ?? 0
        if session.source == .button { await restoreFocusIfNeeded() }
        guard self.session === session else { return }

        // MARK: FLU-5 text — snapshot the field first, so a later correction can be found.
        if Settings.shared.learnFromEdits { EditWatcher.shared.willInsert(output) }
        let outcome = await TextInjector.insert(output)
        if Settings.shared.learnFromEdits, outcome == .inserted { EditWatcher.shared.didInsert() }
        // The paste is awaited above: no `self.session` check would make sense after it, the
        // text has gone where it went.
        recordLatency(session, engineSeconds: engineSeconds)
        // Clement's Whisper context and (opt-in) term learning. In memory only.
        AutoLearningEngine.shared.recordInjectedText(output)
        lastTranscript = output  // MARK: FLU-5 input
        // The success sound only once the text has landed (FLU-27, FLU-29: after the paste).
        if outcome == .inserted, Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }
        // The recording did its job: it leaves memory now.
        forgetKeptRecording()

        switch outcome {
        case .inserted: end(session, as: .idle)
        case .onClipboard(let reason): end(session, showing: .copied(reason))
        case .pasteSkipped: end(session, showing: .failure(.pasteSkipped))
        }
        recordRun(session, text: output, raw: raw, processSeconds: processSeconds, corrections: corrections, engineName: engineName)
    }

    /// Drains the session's audio into the engine, in capture order, on its own task.
    ///
    /// Audio is held back until the silence gate hears something, then released all at
    /// once: a recording that never rises above room tone never reaches the engine at all.
    /// Static and detached so none of it runs on the main actor.
    ///
    /// FLU-29: a copy of the recording is kept in memory as 16 kHz mono (`RecordingReplay`),
    /// so a failed transcription can be run again; nil past `DictationRetry.maxKeptAudioSeconds`.
    /// `engine` is nil when none could start: the recording is then only kept.
    private nonisolated static func feed(
        _ audio: AsyncStream<AudioChunk>,
        to engine: (any TranscriptionEngine)?,
        as format: AVAudioFormat,
        keepingRecording: Bool
    ) -> Task<FeedResult, Never> {
        return Task.detached(priority: .userInitiated) {
            let converter = StreamConverter(output: format)
            let keptFormat = RecordingReplay.format
            // Parakeet's and Whisper's format is the kept one: their buffers are reused.
            let keepConverter = format == keptFormat ? nil : StreamConverter(output: keptFormat)
            var gate = SpeechGate()
            var held: [AudioChunk] = []
            var recording: [AudioChunk] = []
            var kept: [AudioChunk]? = []
            var keptFrames: Double = 0

            func keep(_ buffers: [AVAudioPCMBuffer]) {
                guard kept != nil else { return }
                for buffer in buffers {
                    keptFrames += Double(buffer.frameLength)
                    guard DictationRetry.shouldKeep(audioSeconds: max(1, keptFrames) / keptFormat.sampleRate) else {
                        kept = nil
                        return
                    }
                    kept?.append(AudioChunk(buffer: buffer))
                }
            }

            func deliver(_ buffers: [AVAudioPCMBuffer]) async {
                if keepConverter == nil { keep(buffers) }
                guard let engine else { return }
                for buffer in buffers {
                    let chunk = AudioChunk(buffer: buffer)
                    if keepingRecording { recording.append(chunk) }
                    guard gate.hasSpeech else {
                        held.append(chunk)
                        continue
                    }
                    for waiting in held { await engine.feed(waiting) }
                    held.removeAll()
                    await engine.feed(chunk)
                }
            }

            for await chunk in audio {
                let buffer = chunk.buffer
                if let samples = buffer.floatChannelData?[0] {
                    gate.observe(
                        UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)),
                        sampleRate: buffer.format.sampleRate
                    )
                }
                if let keepConverter { keep(keepConverter.convert(buffer)) }
                await deliver(converter.convert(buffer))
            }
            // The stream ended: flush what the sample-rate converter is still holding, or
            // the end of the last word never reaches the engine.
            if !Task.isCancelled {
                if let keepConverter { keep(keepConverter.drain()) }
                await deliver(converter.drain())
            }
            return FeedResult(recording: recording, gate: gate.verdict, kept: kept?.isEmpty == false ? kept : nil)
        }
    }

    /// The engine's result stream threw.
    private func engineFailed(_ session: DictationSession, _ error: Error) {
        guard self.session === session else { return }
        // English and technical: the log's, not the capsule's.
        Log.speech.error("engine failed during the dictation: \(error.localizedDescription)")
        session.engineError = error
        // FLU-29: still holding the key, the recording goes on — into memory, for the retry
        // at release (`recover`). Nothing to tell the user before then.
    }

    /// Capture ended on its own — the device went away. Finish with what was captured.
    private func captureInterrupted(_ session: DictationSession?, reason: String) {
        guard let session, self.session === session else { return }
        session.interruption = reason
        if !session.isReleased {
            endDictation(from: nil)
        }
    }

    /// Abandons the dictation in progress: nothing is typed, nothing is filed.
    private func cancelDictation(reason: String) {
        // Unconditionally: a held Wispr key outlives everything else here.
        releaseWispr()
        guard let session else { return }
        Log.app.info("dictation cancelled — \(reason, privacy: .public)")
        teardown(session)
        timeline.handle(.dictationEnded, at: Self.uptime)
        state = .idle
        transcript = ""
        level = 0
        levelFollower.reset()
    }

    /// Stops everything a session started and forgets it. The engine is cancelled, not
    /// finished, so Parakeet doesn't spend a transcription pass on audio nobody wants.
    private func teardown(_ session: DictationSession) {
        session.endSignpost("cancelled")
        if self.session === session { self.session = nil }
        capture.stop()
        session.audioInput.finish()
        session.feedTask?.cancel()
        session.consumeTask?.cancel()
        session.limitTask?.cancel()
        let engine = session.engine
        Task { await engine?.cancel() }
    }

    /// A session that ran to the end.
    private func end(_ session: DictationSession, as finalState: State) {
        session.endSignpost("ended")
        session.limitTask?.cancel()
        // Cancelled while the paste was under way (FLU-29 awaits it): the capsule already
        // says « Annulé », or shows what came next.
        guard self.session === session else { return }
        self.session = nil
        if finalState == .idle { timeline.handle(.dictationEnded, at: Self.uptime) }
        state = finalState
        transcript = ""
    }

    // MARK: - Comparison, history, failure

    private static func describe(_ verdict: SpeechGate.Verdict) -> String {
        switch verdict {
        case .accepted: "accepted"
        case .tooShort(let seconds): String(format: "too short (%.2fs)", seconds)
        case .silent: "no speech detected"
        }
    }

    /// How a compare-mode dictation ends: all engines on the same audio, filed as one group.
    /// No text is typed; the user came to read the outputs, not to have one land in an app.
    private func runComparison(_ session: DictationSession, recording chunks: [AudioChunk]) async {
        guard !chunks.isEmpty, let releasedAt = session.releasedAt else {
            end(session, as: .idle)
            return
        }
        let holdStarted = session.started

        transcript = "Comparaison des moteurs…"

        let group = UUID().uuidString
        let holdSeconds = releasedAt.timeIntervalSince(holdStarted)
        // Only engines whose model is already on disk (FLU-48): a comparison downloads nothing.
        let whisperVariant = Settings.shared.whisperModel
        let engines = EngineComparison.plannedEngines(whisperVariant: whisperVariant)
        Log.speech.info("compare · engines: \(engines.map(\.rawValue).joined(separator: ", "), privacy: .public)")

        runningComparisonGroup = group
        defer { if runningComparisonGroup == group { runningComparisonGroup = nil } }

        // Filed engine by engine, so a row shows up without waiting for the slower one.
        let results = await EngineComparison.run(
            chunks: chunks,
            engines: engines,
            whisperVariant: whisperVariant,
            whisperLanguage: Settings.shared.dictationLanguage.whisperLanguageCode
        ) { result in
            RunLog.record(Self.historyRow(result, date: releasedAt, audioSeconds: holdSeconds, group: group))
        }
        guard self.session === session else { return }

        // Lengths only. The text itself is the user's dictation and has no place in the
        // unified log, where `log stream` and every sysdiagnose can read it.
        for result in results {
            Log.speech.info("""
                compare · \(result.engine, privacy: .public) · \
                \(result.seconds, format: .fixed(precision: 2), privacy: .public)s · \
                \(result.text.count, privacy: .public) chars
                """)
        }

        // The local engines are done, and so is the dictation: the next one may start now,
        // whether or not Wispr Flow is still on its way (FLU-48).
        end(session, as: .idle)
        if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }

#if !FLUENCE_WITHOUT_WISPR
        // Wispr last, in the background: its cloud round trip ends after the local engines.
        // Waited for only when Fluence pressed its key for this recording; a comparison started
        // with Fluence's own shortcut has no Wispr row to wait for.
        if ComparisonPlan.waitsForExternalResult(
            installed: WisprReader.isInstalled,
            keyPressedByFluence: session.pressedWispr
        ) {
            let window = ComparisonPlan.externalStampWindow(
                holdStarted: holdStarted,
                releasedAt: releasedAt,
                previousReleasedAt: lastWisprReleasedAt
            )
            lastWisprReleasedAt = releasedAt
            waitForWispr(stampedIn: window, group: group, date: releasedAt, audioSeconds: holdSeconds)
        }
#endif
    }

#if !FLUENCE_WITHOUT_WISPR
    /// Files Wispr Flow's row into the comparison once it shows up, up to 8 s after the local
    /// engines finished, without holding any dictation up meanwhile.
    private func waitForWispr(stampedIn window: ClosedRange<Date>, group: String, date: Date, audioSeconds: Double) {
        groupsWaitingForWispr.insert(group)
        Task { [weak self] in
            let wispr = await WisprReader.result(stampedIn: window, timeout: 8)
            guard let self else { return }
            self.groupsWaitingForWispr.remove(group)
            guard let wispr else {
                Log.speech.info("compare · no Wispr Flow result (the wait timed out)")
                return
            }
            // Deleted while Wispr was finishing: don't bring the comparison back as a lone row.
            guard RunStore.shared.runs.contains(where: { $0.group == group }) else { return }
            RunLog.record(Self.historyRow(wispr, date: date, audioSeconds: audioSeconds, group: group))
            Log.speech.info("""
                compare · \(wispr.engine, privacy: .public) · \
                \(wispr.seconds, format: .fixed(precision: 2), privacy: .public)s end to end · \
                \(wispr.text.count, privacy: .public) chars
                """)
        }
    }
#endif

    /// One engine's result as a history row of its comparison.
    private static func historyRow(_ result: ComparisonResult, date: Date, audioSeconds: Double, group: String) -> DictationRun {
        DictationRun(
            date: date,
            engine: result.engine,
            audioSeconds: audioSeconds,
            processSeconds: result.seconds,
            text: result.text,
            group: group,
            failed: result.failed,
            endToEnd: result.endToEnd
        )
    }

    /// Files the finished utterance in the history.
    ///
    /// `processSeconds` counts from key-up. That is the delay the user notices, and it puts a
    /// streaming engine and a batch engine on equal footing.
    private func recordRun(
        _ session: DictationSession,
        text: String,
        raw: String,
        processSeconds: Double,
        corrections: [AppliedCorrection],
        engineName: String? = nil
    ) {
        guard let releasedAt = session.releasedAt else { return }
        let rawText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        RunLog.record(
            DictationRun(
                date: releasedAt,
                // The engine that produced the text: after a retry, not the one that failed.
                engine: engineName ?? session.engineName,
                audioSeconds: releasedAt.timeIntervalSince(session.started),
                processSeconds: processSeconds,
                text: text,
                rawText: rawText == text ? nil : rawText,
                corrections: corrections.isEmpty ? nil : corrections
            )
        )
    }

    /// FLU-31: the tail's timings, into the signpost and the timings-only counter. The end of
    /// speech is where the last sound ended in the capture, before or after the release.
    private func recordLatency(_ session: DictationSession, engineSeconds: Double) {
        let now = HostClock.now
        guard let released = session.releasedHostTime, let releasedAt = session.releasedAt else { return }
        let speechEnd = session.trail.snapshot.lastSoundEnd
        let sample = DictationLatency(
            postRoll: session.postRollSeconds,
            engine: engineSeconds,
            keyUpToText: now - released,
            speechEndToText: speechEnd.map { now - $0 },
            audioSeconds: releasedAt.timeIntervalSince(session.started)
        )
        LatencyLog.record(sample)
        let milliseconds = Int(((sample.speechEndToText ?? sample.keyUpToText) * 1_000).rounded())
        session.endSignpost("inserted", millisecondsAfterSpeech: milliseconds)
    }

    /// Rises fast when you speak, falls back over a few hundred milliseconds (FLU-23).
    private func updateLevel(_ new: Float, over duration: TimeInterval) {
        // Post-roll and stray late buffers keep arriving after release; the meter has
        // already dropped to zero by then and should stay there.
        guard state == .starting || state == .listening else { return }
        level = levelFollower.update(target: new, dt: duration)
    }

    private func fail(_ failure: DictationFailure) {
        // Fixed words only: never the engine's text, never the transcript.
        Log.app.error("dictation failed: \(failure.kind, privacy: .public)")
        Diagnostics.error("dictation.failed")
        // A held Wispr key outlives our failure: Wispr would keep recording, and uploading.
        releaseWispr()
        if let session { teardown(session) }
        transcript = ""
        level = 0
        levelFollower.reset()
        show(.failure(failure))
    }

    // MARK: - FLU-29: the capsule's messages

    /// The monotonic clock the capsule's timing runs on: sleep and clock changes don't skew it.
    fileprivate static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Puts a message on the capsule, as a new one (its own identity), and arms its timer.
    fileprivate func show(_ message: CapsuleMessage) {
        timeline.handle(.show(message), at: Self.uptime)
        guard let id = timeline.messageID else { return }
        state = .message(message, id: id)
        Task { [weak self] in await self?.dismissWhenDue(id) }
    }

    /// Takes message `id` down once its time is up, counting only the time the pointer was not
    /// on the capsule. Stands down as soon as another message or a dictation replaced it.
    private func dismissWhenDue(_ id: UInt64) async {
        while timeline.messageID == id {
            guard let deadline = timeline.deadline else {
                // Held by the pointer: look again shortly.
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            let wait = deadline - Self.uptime
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                continue
            }
            timeline.handle(.timerFired(id: id), at: Self.uptime)
            if timeline.phase == .hidden, case .message(_, let shown) = state, shown == id, session == nil {
                state = .idle
            }
        }
    }

    /// The pointer entered or left the capsule: a message's clock stops while it is there.
    func capsuleHoverChanged(_ isInside: Bool) {
        timeline.handle(.hover(isInside), at: Self.uptime)
    }

    /// The message's one button.
    func performCapsuleAction() {
        guard case .message(let message, let id) = state, let action = message.action else { return }
        timeline.handle(.actionTaken(id: id), at: Self.uptime)
        state = .idle
        switch action {
        case .retry:
            Task { await retryKeptRecording() }
        case .microphoneSettings:
            Permissions.openMicrophoneSettings()
        case .soundSettings:
            Permissions.openSoundInputSettings()
        case .accessibilitySettings:
            Permissions.openAccessibilitySettings()
        }
    }

    // MARK: - FLU-29: the kept recording

    private func keep(_ recording: KeptRecording) {
        keptRecording = recording
        keptRecordingExpiry?.cancel()
        let keptAt = recording.keptAt
        keptRecordingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DictationRetry.keepSeconds))
            guard !Task.isCancelled, let self, self.keptRecording?.keptAt == keptAt else { return }
            self.forgetKeptRecording()
        }
    }

    /// Drops the recording from memory: success, expiry, or a newer one.
    private func forgetKeptRecording() {
        guard keptRecording != nil else { return }
        keptRecording = nil
        keptRecordingExpiry?.cancel()
        keptRecordingExpiry = nil
        Log.speech.info("kept recording released")
    }

    /// *Réessayer*: the kept recording through another engine, and the text into the app it
    /// was meant for — still checked at the moment of typing.
    private func retryKeptRecording() async {
        guard session == nil else { return }
        guard let kept = keptRecording, DictationRetry.isAvailable(keptAt: kept.keptAt, now: Self.uptime) else {
            forgetKeptRecording()
            show(.failure(.recordingExpired))
            return
        }
        ParakeetDownload.shared.refresh()
        let engine = DictationRetry.otherEngine(
            than: kept.failedEngine,
            parakeetReady: ParakeetDownload.shared.isReady,
            whisperReady: WhisperModels.isDownloaded(variant: Settings.shared.whisperModel)
        )
        let kind = SpeechEngineChoice(engine)
        let session = DictationSession(source: .retry, isComparing: false, engineName: kind.displayName, engineKind: kind, started: kept.started)
        session.releasedAt = kept.releasedAt
        session.target = kept.target
        self.session = session
        sessionEngine = kind
        timeline.handle(.dictationStarted, at: Self.uptime)
        state = .finishing
        transcript = ""
        Log.speech.info("dictation · retry asked for, on \(engine.rawValue, privacy: .public)")

        let started = HostClock.now
        let result = await replay(kept.chunks, on: kind)
        guard self.session === session else { return }
        switch result {
        case .success(let text) where !TranscriptHealth.isDegenerate(text):
            await deliver(text, session: session, engineSeconds: HostClock.now - started)
        case .success:
            keptRecording?.failedEngine = engine
            fail(.repeated(engine, canRetry: DictationRetry.isAvailable(keptAt: kept.keptAt, now: Self.uptime)))
        case .failure:
            keptRecording?.failedEngine = engine
            fail(.engineFailed(engine, canRetry: DictationRetry.isAvailable(keptAt: kept.keptAt, now: Self.uptime)))
        }
    }

    // MARK: - FLU-29: helpers

    /// The name of the microphone dictation listens to, for « Rien entendu ». A device name,
    /// shown on the capsule and never logged.
    fileprivate static func microphoneName() -> String? {
        let uid = Settings.shared.selectedMicrophoneUID
        let devices = AudioDevices.availableInputDevices()
        if uid != "default", let chosen = devices.first(where: { $0.id == uid }) { return chosen.name }
        guard let defaultID = AudioDevices.defaultInputDeviceID() else { return nil }
        return devices.first { $0.deviceID == defaultID }?.name
    }
}

// MARK: FLU-5 input

extension DictationController {
    /// The HUD's Stop key: ends a hands-free dictation and types it.
    func stopHandsFree() {
        guard isHandsFree else { return }
        endDictation(from: nil)
    }
}

extension DictationController {
    /// What the push-to-talk key's gestures ask for. See `PushToTalkGesture`.
    fileprivate func handleGesture(_ action: PushToTalkGesture.Action) {
        switch action {
        case .start(let command):
            // A press while the last dictation is still finishing does nothing, as before;
            // the gesture machine must then ignore that press's release too.
            guard session == nil else {
                hotkey.sessionEnded()
                return
            }
            if command, !FoundationModelFormatter.isAvailable {
                hotkey.sessionEnded()
                showNotice(CommandRewriter.Failure.unavailable.message)
                return
            }
            beginDictation(from: .hotkey, command: command)

        case .enterHandsFree:
            guard let session, session.source == .hotkey, !session.isReleased else { return }
            isHandsFree = true
            Log.app.info("dictation is hands-free")

        case .markCommand:
            guard let session, session.source == .hotkey, !session.isReleased, !session.isComparing,
                  !isCommand
            else { return }
            if !FoundationModelFormatter.isAvailable {
                cancelDictation(reason: "Command Mode unavailable")
                showNotice(CommandRewriter.Failure.unavailable.message)
                return
            }
            isCommand = true

        case .finish:
            endDictation(from: .hotkey)
        }
    }

    /// Esc cancels whatever is recording or finishing — nothing typed, nothing filed. Only
    /// then is the key swallowed; an idle Fluence leaves Esc to the app.
    fileprivate func cancelFromEscape() -> Bool {
        guard session != nil, state.isActive else { return false }
        cancelDictation(reason: "Esc")
        // FLU-12: the capsule says so for a moment, in its place, instead of vanishing.
        showMessage(.cancelled)
        return true
    }

    /// ⌃⌘V types the last transcript again; ⌃⌘C puts it on the pasteboard.
    fileprivate func handleLastTranscript(_ action: LastTranscriptAction) {
        // Mid-dictation the chord is swallowed and ignored: pasting now would land in the
        // middle of what is being said.
        guard session == nil else { return }
        guard let text = lastTranscript else {
            showNotice("Rien n'a encore été dicté.")
            return
        }
        switch action {
        case .paste:
            Task {
                // ⌃ and ⌘ are still down on the chord. The paste fallback posts its own ⌘V,
                // which must not reach the app as ⌃⌘V.
                await Self.waitForChordRelease()
                guard self.session == nil else { return }
                // FLU-29: the capsule says where it went when it did not land.
                switch await TextInjector.insert(text) {
                case .inserted: break
                case .onClipboard(let reason): self.showMessage(.copied(reason))
                case .pasteSkipped: self.showMessage(.failure(.pasteSkipped))
                }
            }
        case .copy:
            // Asked for, so an ordinary copy — but this Mac only: Universal Clipboard would
            // hand the dictation to every device on the account.
            let pasteboard = NSPasteboard.general
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            pasteboard.setString(text, forType: .string)
            showNotice("Dernière transcription copiée.")
        }
    }

    private static func waitForChordRelease() async {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if !flags.contains(.maskControl), !flags.contains(.maskCommand) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Command Mode, once the instruction is transcribed: read the selection (or the whole
    /// field), rewrite it on-device, put it back. The text is never logged.
    fileprivate func runCommand(_ session: DictationSession, instruction: String) async {
        let target: CommandTarget
        switch CommandTarget.read() {
        case .success(let found):
            target = found
        case .failure(let failure):
            Log.app.info("command · no target (\(String(describing: failure), privacy: .public))")
            end(session, notice: failure.message)
            return
        }

        transcript = "Réécriture…"
        let result = await CommandRewriter.rewrite(target.text, instruction: instruction)
        // Esc, a lock screen or a new session while the model worked: write nothing.
        guard self.session === session else { return }

        switch result {
        case .success(let rewritten):
            guard await target.replace(with: rewritten) else {
                Log.app.info("command · focus or selection moved during the rewrite — nothing replaced")
                end(session, notice: "Le texte a changé entre-temps. Rien n'a été remplacé.")
                return
            }
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }
            end(session, as: .idle)
        case .failure(let failure):
            Log.app.info("command · \(failure.reason, privacy: .public)")
            end(session, notice: failure.message)
        }
    }

    private func end(_ session: DictationSession, notice message: String) {
        end(session, showing: .notice(message))
    }

    /// A session that ran to the end with something to say (FLU-29).
    fileprivate func end(_ session: DictationSession, showing message: CapsuleMessage) {
        session.endSignpost("ended")
        session.limitTask?.cancel()
        guard self.session === session else { return }
        self.session = nil
        transcript = ""
        show(message)
    }

    /// A notice outside any dictation. Never over one: the HUD is showing the recording.
    fileprivate func showNotice(_ message: String) {
        showMessage(.notice(message))
    }

    fileprivate func showMessage(_ message: CapsuleMessage) {
        guard session == nil else { return }
        transcript = ""
        show(message)
    }
}

// MARK: end FLU-5 input

/// One dictation, from key-down to text typed.
///
/// The controller holds at most one, and the object's identity is the session token: after
/// every `await`, a step checks `controller.session === session` before touching shared
/// state. A session that was cancelled or replaced while it waited — a slow Parakeet load,
/// a lock screen, a release and re-press — finds out and stands down, instead of driving
/// the capture, the HUD or the injector of whatever came after it.
@MainActor
private final class DictationSession {
    /// `retry`: the capsule's *Réessayer* on a kept recording (FLU-29); no microphone.
    enum Source { case hotkey, button, retry }

    let source: Source
    let isComparing: Bool
    let engineName: String
    /// The engine this dictation runs on (FLU-29: the one a failure names).
    let engineKind: SpeechEngineChoice
    let started: Date
    var releasedAt: Date?
    var isReleased: Bool { releasedAt != nil }
    /// The release on the host clock, which the capture's buffers are stamped with.
    var releasedHostTime: TimeInterval?
    /// Where the last sound ended, for the post-roll (FLU-31).
    let trail = TrailingSilenceMonitor()
    /// Key-up → microphone closed, once the post-roll is over.
    var postRollSeconds: Double = 0
    /// The key-up → text interval (FLU-31), until it is ended.
    var signpost: OSSignpostIntervalState?
    var signpostID: OSSignpostID?

    /// Ends the interval once, whichever way the session ends. Numbers and fixed words only.
    func endSignpost(_ outcome: String, millisecondsAfterSpeech: Int? = nil) {
        guard let signpost else { return }
        self.signpost = nil
        if let millisecondsAfterSpeech {
            Log.signposter.endInterval("Dictation", signpost, "\(outcome, privacy: .public), \(millisecondsAfterSpeech, privacy: .public) ms after the end of speech")
        } else {
            Log.signposter.endInterval("Dictation", signpost, "\(outcome, privacy: .public)")
        }
    }

    /// Captured audio, waiting for the engine. Unbounded on purpose — this *is* the
    /// pre-roll, holding whatever was said while the engine loaded — and bounded in
    /// practice by the recording limit.
    let audio: AsyncStream<AudioChunk>
    let audioInput: AsyncStream<AudioChunk>.Continuation

    var captureStarted = false
    /// The engine is started and the feed task running.
    var isReady = false
    var engine: (any TranscriptionEngine)?
    var feedTask: Task<FeedResult, Never>?
    var consumeTask: Task<Void, Never>?
    var limitTask: Task<Void, Never>?
    /// The engine's result stream threw.
    var engineError: Error?
    /// FLU-29: the engine never started; the recording was only kept, for another engine.
    var startError: Error?
    /// Capture ended on its own; the reason, for the log.
    var interruption: String?
    /// Fluence pressed Wispr Flow's key for this recording (compare mode, Record button), so
    /// Wispr heard it and its row is worth waiting for.
    var pressedWispr = false
    // MARK: FLU-5 text
    /// The frontmost app at release, and its category — the style at level High.
    var target: FrontmostApp.Target?

    init(source: Source, isComparing: Bool, engineName: String, engineKind: SpeechEngineChoice, started: Date = Date()) {
        self.source = source
        self.isComparing = isComparing
        self.engineName = engineName
        self.engineKind = engineKind
        self.started = started
        (audio, audioInput) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
    }
}

/// What the feed task hands back once the audio stream ends.
private struct FeedResult: Sendable {
    /// Compare mode only: the recording in the engine's format, so every engine replays it.
    var recording: [AudioChunk]
    var gate: SpeechGate.Verdict
    /// FLU-29: the whole recording at 16 kHz mono, for a retry; nil when too long to keep.
    var kept: [AudioChunk]?
}
