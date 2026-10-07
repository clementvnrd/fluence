import FluenceCore
import MurmurDictionary
import AVFoundation
import AppKit
import Foundation
import Observation

/// Builds the engine named by the current setting.
///
/// Reading the setting per-utterance is what lets the menu's engine picker take effect on
/// the very next hold instead of needing a restart. Main-actor isolated like the setting it
/// reads — it used to be `@Sendable` and *assert* main-actor isolation inside, which traps
/// the moment anything calls it from elsewhere.
@MainActor
func engineForCurrentSetting() -> any TranscriptionEngine {
    switch Settings.shared.engine {
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
        case idle
        case starting
        case listening
        case finishing
        case error(String)
        // MARK: FLU-5 input
        /// A short message that is not a fault — "Last transcript copied", "Select some text
        /// first". Shown on the HUD for a moment, then back to idle.
        case notice(String)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .error, .notice: false
            }
        }

        /// The HUD shows errors as well as activity: an error that only reaches the log is
        /// indistinguishable, to the user, from the key doing nothing.
        var showsHUD: Bool {
            switch self {
            case .error, .notice: true
            default: isActive
            }
        }
    }

    private(set) var state: State = .idle
    /// Live transcript, updated as the engine revises it. Drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0

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
            hotkey.sessionEnded()
        }
    }

    /// How long the mic stays open after the key comes up. People release on the last
    /// syllable, not after it.
    private static let postRoll: Duration = .milliseconds(250)

    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        formatter: (any TextFormatter)? = nil,
        makeEngine: @escaping @MainActor () -> any TranscriptionEngine = engineForCurrentSetting
    ) {
        self.formatter = formatter
        self.makeEngine = makeEngine
    }

    // MARK: - Lifecycle

    /// - Returns: `false` if the hotkey tap couldn't be installed (missing Accessibility).
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

    // MARK: - Button-driven recording

    /// Starts a recording from a Record button rather than the hotkey.
    ///
    /// Wispr Flow's hotkey is held down for the duration **only in compare mode**. Reaching
    /// into another app is a comparison affordance; during ordinary dictation it would mean
    /// every recording silently shipped your audio to a third party's servers.
    func startButtonRecording() {
        guard session == nil else { return }
        if Settings.shared.compareMode { WisprTrigger.press() }
        beginDictation(from: .button)
    }

    /// Releases Wispr's hotkey first, so its upload starts while our own engines are still
    /// finishing — otherwise every run would wait the full round trip end to end.
    func stopButtonRecording() {
        WisprTrigger.release()
        endDictation(from: nil)
    }

    // MARK: - Dictation

    /// Key down. The mic opens *now*, before the engine is ready: whatever is said while the
    /// engine loads waits in the session's stream and reaches the engine first, in order.
    private func beginDictation(from source: DictationSession.Source, command: Bool = false) {
        guard session == nil else { return }

        // A Command Mode instruction is never a comparison: it is applied, not compared.
        let isComparing = Settings.shared.compareMode && !command
        let session = DictationSession(
            source: source,
            isComparing: isComparing,
            engineName: isComparing ? "Comparaison…" : Settings.shared.engine.displayName
        )
        self.session = session
        isCommand = command
        state = .starting
        transcript = ""
        level = 0

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
        do {
            try capture.start(
                deviceUID: Settings.shared.selectedMicrophoneUID,
                onBuffer: { chunk in input.yield(chunk) },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.updateLevel(level) }
                },
                onInterrupted: { [weak self, weak session] reason in
                    Task { @MainActor in self?.captureInterrupted(session, reason: reason) }
                }
            )
        } catch {
            fail(error.localizedDescription)
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
                    fail("L'accès au micro est désactivé. Autorisez-le dans Réglages Système ▸ Confidentialité et sécurité ▸ Micro.")
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

        do {
            let chunks = try await engine.start()
            guard self.session === session else {
                await engine.cancel()
                return
            }

            // Compare mode captures in *Apple's* format, not a format of our choosing.
            //
            // SpeechAnalyzer enforces `Audio sample data must be 16-bit signed integers`
            // as a hard precondition — feeding it float32 doesn't fail gracefully, it
            // kills the process. Parakeet is the flexible one (its `feed` converts
            // int16/int32/float32), so the strict engine picks the format and the
            // tolerant engine adapts. Both still replay the identical buffers.
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
                    for try await chunk in chunks {
                        guard let self, self.session === session else { return }
                        self.transcript = chunk.text
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
            fail(error.localizedDescription)
        }
    }

    /// Key up. Capture runs on for the post-roll, then the session completes — now if the
    /// engine is ready, or as soon as `prepare` gets it there.
    private func endDictation(from source: DictationSession.Source?) {
        guard let session, !session.isReleased else { return }
        // The hotkey's release must not stop a recording the Record button started.
        if let source, source != session.source { return }

        WisprTrigger.release()
        session.releasedAt = Date()
        // MARK: FLU-5 text — where the text will go, read now while that app is in front.
        session.target = FrontmostApp.capture(readURL: Settings.shared.cleanupLevel.appliesStyle)
        session.limitTask?.cancel()
        state = .finishing
        level = 0

        Task { await stopCaptureAfterPostRoll(session) }
        if session.isReady {
            Task { await complete(session) }
        }
    }

    private func stopCaptureAfterPostRoll(_ session: DictationSession) async {
        if session.captureStarted, capture.isRunning {
            try? await Task.sleep(for: Self.postRoll)
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
            if let interruption = session.interruption {
                fail(interruption)
            } else {
                end(session, as: .idle)
            }
            return
        }

        await session.engine?.finish()
        guard self.session === session else { return }
        await session.consumeTask?.value
        guard self.session === session else { return }

        if session.isComparing {
            await runComparison(session, recording: fed.recording)
            return
        }

        let raw = transcript
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // An engine that failed and an engine that heard nothing look the same from
            // here; only the first is worth telling the user about.
            if let error = session.engineError {
                fail(error.localizedDescription)
            } else {
                end(session, as: .idle)
            }
            return
        }

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
        // MARK: FLU-5 text — snapshot the field first, so a later correction can be found.
        if session.source == .button { await restoreFocusIfNeeded() }
        guard self.session === session else { return }
        if Settings.shared.learnFromEdits { EditWatcher.shared.willInsert(output) }
        TextInjector.insert(output)
        // Clement's Whisper context and (opt-in) term learning. In memory only.
        AutoLearningEngine.shared.recordInjectedText(output)
        lastTranscript = output  // MARK: FLU-5 input
        if Settings.shared.learnFromEdits { EditWatcher.shared.didInsert() }
        if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }

        // Text arrived, but the engine also failed partway: type what there is, and say so.
        if let error = session.engineError {
            fail("La transcription s'est arrêtée trop tôt : \(error.localizedDescription)")
        } else {
            end(session, as: .idle)
        }
        recordRun(session, text: output, raw: raw, processSeconds: processSeconds, corrections: corrections)
    }

    /// Drains the session's audio into the engine, in capture order, on its own task.
    ///
    /// Audio is held back until the silence gate hears something, then released all at
    /// once: a recording that never rises above room tone never reaches the engine at all.
    /// Static and detached so none of it runs on the main actor.
    private nonisolated static func feed(
        _ audio: AsyncStream<AudioChunk>,
        to engine: any TranscriptionEngine,
        as format: AVAudioFormat,
        keepingRecording: Bool
    ) -> Task<FeedResult, Never> {
        return Task.detached(priority: .userInitiated) {
            let converter = StreamConverter(output: format)
            var gate = SpeechGate()
            var held: [AudioChunk] = []
            var recording: [AudioChunk] = []

            func deliver(_ buffers: [AVAudioPCMBuffer]) async {
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
                await deliver(converter.convert(buffer))
            }
            // The stream ended: flush what the sample-rate converter is still holding, or
            // the end of the last word never reaches the engine.
            if !Task.isCancelled {
                await deliver(converter.drain())
            }
            return FeedResult(recording: recording, gate: gate.verdict)
        }
    }

    /// The engine's result stream threw.
    private func engineFailed(_ session: DictationSession, _ error: Error) {
        guard self.session === session else { return }
        session.engineError = error
        // Still holding the key: the engine is dead, so there's no point recording on.
        // Already released: `complete` reports it once the tail has run.
        if !session.isReleased {
            fail(error.localizedDescription)
        }
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
        WisprTrigger.release()
        guard let session else { return }
        Log.app.info("dictation cancelled — \(reason, privacy: .public)")
        teardown(session)
        state = .idle
        transcript = ""
        level = 0
    }

    /// Stops everything a session started and forgets it. The engine is cancelled, not
    /// finished, so Parakeet doesn't spend a transcription pass on audio nobody wants.
    private func teardown(_ session: DictationSession) {
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
        session.limitTask?.cancel()
        if self.session === session { self.session = nil }
        state = finalState
        transcript = ""
    }

    // MARK: - Helpers

    private static func describe(_ verdict: SpeechGate.Verdict) -> String {
        switch verdict {
        case .accepted: "accepted"
        case .tooShort(let seconds): String(format: "too short (%.2fs)", seconds)
        case .silent: "no speech detected"
        }
    }

    /// Replays the recording through every engine and files the results as one group.
    ///
    /// Nothing is injected in this mode — the point is to read the outputs side by side,
    /// and typing one of them into whatever had focus would be a surprise.
    private func runComparison(_ session: DictationSession, recording chunks: [AudioChunk]) async {
        guard !chunks.isEmpty, let releasedAt = session.releasedAt else {
            end(session, as: .idle)
            return
        }
        let holdStarted = session.started

        transcript = "Comparaison des moteurs…"

        let group = UUID().uuidString
        let held = releasedAt.timeIntervalSince(holdStarted)

        // Filed one at a time as each engine finishes, so the window fills in progressively
        // rather than snapping both rows into place at the end.
        let results = await EngineComparison.run(chunks: chunks) { result in
            RunLog.record(
                DictationRun(
                    date: releasedAt,
                    engine: result.engine,
                    audioSeconds: held,
                    processSeconds: result.seconds,
                    text: result.text,
                    group: group
                )
            )
        }
        guard self.session === session else { return }

        // Lengths only. The text itself is the user's dictation and has no place in the
        // unified log, where `log stream` and every sysdiagnose can read it.
        for result in results {
            Log.speech.info("""
                compare · \(result.engine, privacy: .public): \
                \(result.seconds, format: .fixed(precision: 2))s — \
                \(result.text.count, privacy: .public) chars
                """)
        }

        // Wispr Flow, if its hotkey was held for this same utterance. It transcribes in the
        // cloud, so its row lands after both local engines have already finished — the wait
        // happens here rather than blocking the rows above from appearing.
        if WisprReader.isInstalled {
            transcript = "En attente de Wispr Flow…"
            if let wispr = await WisprReader.result(after: holdStarted, timeout: 8) {
                guard self.session === session else { return }
                RunLog.record(
                    DictationRun(
                        date: releasedAt,
                        engine: wispr.engine,
                        audioSeconds: held,
                        processSeconds: wispr.seconds,
                        text: wispr.text,
                        group: group
                    )
                )
                Log.speech.info("""
                    compare · \(wispr.engine, privacy: .public): \
                    \(wispr.seconds, format: .fixed(precision: 2))s — \
                    \(wispr.text.count, privacy: .public) chars
                    """)
            } else {
                Log.speech.info("compare · Wispr Flow: no result (hotkey not held, or timed out)")
            }
        }

        guard self.session === session else { return }
        end(session, as: .idle)
        if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
    }

    /// Files the finished utterance in the history.
    ///
    /// `processSeconds` is measured from key release, not from capture start — that's the
    /// wait the user actually experiences, and it's the only number on which a streaming
    /// engine and a batch engine can be compared honestly.
    private func recordRun(
        _ session: DictationSession,
        text: String,
        raw: String,
        processSeconds: Double,
        corrections: [AppliedCorrection]
    ) {
        guard let releasedAt = session.releasedAt else { return }
        let rawText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        RunLog.record(
            DictationRun(
                date: releasedAt,
                engine: session.engineName,
                audioSeconds: releasedAt.timeIntervalSince(session.started),
                processSeconds: processSeconds,
                text: text,
                rawText: rawText == text ? nil : rawText,
                corrections: corrections.isEmpty ? nil : corrections
            )
        )
    }

    /// Light smoothing so the waveform glides instead of strobing at buffer rate.
    private func updateLevel(_ new: Float) {
        // Post-roll and stray late buffers keep arriving after release; the meter has
        // already dropped to zero by then and should stay there.
        guard state == .starting || state == .listening else { return }
        level += (new - level) * 0.35
    }

    private func fail(_ message: String) {
        Log.app.error("\(message)")
        // A held Wispr key outlives our failure: Wispr would keep recording, and uploading.
        WisprTrigger.release()
        if let session { teardown(session) }
        state = .error(message)
        transcript = ""
        level = 0

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if state == .error(message), session == nil { state = .idle }
        }
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
            if case .error = state { state = .idle }
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
        showNotice(Self.cancelledNotice)
        return true
    }

    /// The notice an Esc cancel leaves on the HUD; the HUD draws it as its "Annulé" state.
    static let cancelledNotice = "Annulé"

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
                TextInjector.insert(text)
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
            guard target.replace(with: rewritten) else {
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
        end(session, as: .notice(message))
        dismissNoticeLater(message)
    }

    /// A notice outside any dictation. Never over one: the HUD is showing the recording.
    fileprivate func showNotice(_ message: String) {
        guard session == nil else { return }
        state = .notice(message)
        transcript = ""
        dismissNoticeLater(message)
    }

    private func dismissNoticeLater(_ message: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if state == .notice(message), session == nil { state = .idle }
        }
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
    enum Source { case hotkey, button }

    let source: Source
    let isComparing: Bool
    let engineName: String
    let started = Date()
    var releasedAt: Date?
    var isReleased: Bool { releasedAt != nil }

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
    /// Capture ended on its own; the reason, for the user.
    var interruption: String?
    // MARK: FLU-5 text
    /// The frontmost app at release, and its category — the style at level High.
    var target: FrontmostApp.Target?

    init(source: Source, isComparing: Bool, engineName: String) {
        self.source = source
        self.isComparing = isComparing
        self.engineName = engineName
        (audio, audioInput) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
    }
}

/// What the feed task hands back once the audio stream ends.
private struct FeedResult: Sendable {
    /// Compare mode only: the recording in the engine's format, so every engine replays it.
    var recording: [AudioChunk]
    var gate: SpeechGate.Verdict
}
