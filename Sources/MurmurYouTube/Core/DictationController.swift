import MurmurDictionary
import AVFoundation
import AppKit
import Foundation
import Observation

/// Builds the engine named by the current setting.
///
/// Deliberately at file scope rather than a static on `DictationController`: the class is
/// `@MainActor`, which would make a static method main-actor-isolated and therefore
/// ineligible to be `@Sendable`. Reading the setting per-utterance is what lets the menu's
/// engine picker take effect on the very next hold instead of needing a restart.
@Sendable
func engineForCurrentSetting() -> any TranscriptionEngine {
    // Always invoked from `beginDictation`, which runs on the main actor.
    MainActor.assumeIsolated {
        switch Settings.shared.engine {
        case .apple: AppleSpeechEngine(locale: Settings.shared.language.locale)
        case .whisper: WhisperEngine(variant: Settings.shared.whisperModel, language: Settings.shared.language.whisperLanguageCode)
        case .parakeet: ParakeetEngine()
        }
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

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .error: false
            }
        }
    }

    private(set) var state: State = .idle
    /// Live transcript, updated as the engine revises it. Drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0
    /// Whether the current recording is Command Mode (transforming selected text).
    private(set) var isCommandMode = false
    private var selectedTextForCommand: String?

    /// Whether the keyboard hook / event tap is currently running.
    var isHotkeyActive: Bool { hotkey.isActive }

    private let hotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    private let makeEngine: @Sendable () -> any TranscriptionEngine

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?

    /// Chosen per-utterance so the menu toggle applies to the very next hold.
    private var activeFormatter: any TextFormatter {
        if let formatter { return formatter }
        // Whisper is already a deep neural network that directly emits punctuated,
        // capitalized, and grammatically formatted text. Running FoundationModelFormatter
        // (Apple Intelligence LLM) on top adds ~3.5s of redundant latency.
        // RuleBasedFormatter handles filler stripping, backtracking, and developer symbols in 0.001s.
        if Settings.shared.engine == .whisper {
            return Settings.shared.smartCleanupOnWhisper
                ? FoundationModelFormatter()
                : RuleBasedFormatter()
        }
        return Settings.shared.smartCleanup
            ? FoundationModelFormatter()
            : RuleBasedFormatter()
    }

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    /// Returns the ordered recording when compare mode is on, empty otherwise.
    private var feedTask: Task<[AudioChunk], Never>?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?

    /// Timestamps for the dashboard: when the key went down, and when it came up.
    private var holdStarted: Date?
    private var releasedAt: Date?
    private var engineName = ""

    /// Compare mode only: the recording, kept so every engine sees identical audio.
    private var recorded: [AudioChunk] = []
    private var isComparing = false

    private var lastExternalApp: NSRunningApplication?
    private var workspaceObserver: (any NSObjectProtocol)?

    init(
        formatter: (any TextFormatter)? = nil,
        makeEngine: @escaping @Sendable () -> any TranscriptionEngine = engineForCurrentSetting
    ) {
        self.formatter = formatter
        self.makeEngine = makeEngine

        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            self.lastExternalApp = front
        }

        self.workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                Task { @MainActor [weak self] in
                    self?.lastExternalApp = app
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// - Returns: `false` if the hotkey tap couldn't be installed (missing Accessibility).
    @discardableResult
    func activate() -> Bool {
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.commandKey = Settings.shared.commandModeEnabled ? Settings.shared.commandModeKey : nil
        hotkey.onPress = { [weak self] in self?.handleHotkeyPress() }
        hotkey.onRelease = { [weak self] in self?.handleHotkeyRelease() }
        hotkey.onCommandPress = { [weak self] in self?.handleCommandPress() }
        hotkey.onCommandRelease = { [weak self] in self?.handleCommandRelease() }
        hotkey.onLanguageToggle = { [weak self] in self?.handleLanguageToggle() }
        return hotkey.start()
    }

    private func handleLanguageToggle() {
        Settings.shared.toggleLanguage()
        if Settings.shared.soundEnabled { NSSound(named: "Tink")?.play() }
    }

    private var isToggledRecording = false

    private func handleHotkeyPress() {
        if state.isActive {
            isToggledRecording = false
            endDictation()
        } else {
            isToggledRecording = false
            beginDictation()
        }
    }

    private func handleHotkeyRelease() {
        guard let started = holdStarted else { return }
        let duration = Date().timeIntervalSince(started)
        if duration < 0.35 {
            isToggledRecording = true
        } else {
            isToggledRecording = false
            endDictation()
        }
    }

    private func handleCommandPress() {
        if state.isActive {
            isToggledRecording = false
            endDictation()
        } else {
            isToggledRecording = false
            beginCommandMode()
        }
    }

    private func handleCommandRelease() {
        guard let started = holdStarted else { return }
        let duration = Date().timeIntervalSince(started)
        if duration < 0.35 {
            isToggledRecording = true
        } else {
            isToggledRecording = false
            endDictation()
        }
    }

    private func beginCommandMode() {
        guard case .idle = state else { return }
        isCommandMode = true
        selectedTextForCommand = TextInjector.getSelectedText()
        if let sel = selectedTextForCommand {
            Log.inject.info("Command Mode: selected text captured (\(sel.count) chars)")
        } else {
            Log.inject.info("Command Mode: no selection detected")
        }
        startDictationInternal()
    }

    func deactivate() {
        hotkey.stop()
        cancelDictation()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    /// Re-arms the tap after the user picks a different push-to-talk key.
    @discardableResult
    func reloadHotkey() -> Bool {
        hotkey.stop()
        return activate()
    }

    // MARK: - Button-driven recording

    /// Starts a recording from a Record button rather than the hotkey.
    ///
    /// Wispr Flow's hotkey is held down for the duration **only in compare mode**. Reaching
    /// into another app is a comparison affordance; during ordinary dictation it would mean
    /// every recording silently shipped your audio to a third party's servers.
    func startButtonRecording() {
        guard case .idle = state else { return }
        if Settings.shared.compareMode { WisprTrigger.press() }
        beginDictation()
    }

    /// Releases Wispr's hotkey first, so its upload starts while our own engines are still
    /// finishing — otherwise every run would wait the full round trip end to end.
    func stopButtonRecording() {
        WisprTrigger.release()
        if case .finishing = state {
            cancelDictation()
            return
        }
        endDictation()
    }

    // MARK: - Dictation

    private func beginDictation() {
        isCommandMode = false
        selectedTextForCommand = nil
        startDictationInternal()
    }

    private func startDictationInternal() {
        if case .error = state {
            state = .idle
        }
        guard case .idle = state else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = front
        }
        state = .starting
        transcript = ""
        holdStarted = Date()
        isComparing = Settings.shared.compareMode
        recorded.removeAll(keepingCapacity: true)
        engineName = isComparing ? "Comparing…" : (isCommandMode ? "Command Mode" : Settings.shared.engine.displayName)

        Task { @MainActor [self] in
            do {
                guard await Permissions.requestMicrophone() else {
                    fail("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                    return
                }

                let engine = makeEngine()
                self.engine = engine

                // Compare mode captures in *Apple's* format, not a format of our choosing.
                //
                // SpeechAnalyzer enforces `Audio sample data must be 16-bit signed integers`
                // as a hard precondition — feeding it float32 doesn't fail gracefully, it
                // kills the process. Parakeet is the flexible one (its `feed` converts
                // int16/int32/float32), so the strict engine picks the format and the
                // tolerant engine adapts. Both still replay the identical buffers.
                let formatOwner: any TranscriptionEngine = isComparing ? AppleSpeechEngine() : engine
                guard let format = await formatOwner.preferredInputFormat() else {
                    throw TranscriptionError.noAudioFormat
                }

                // Audio must reach the engine in capture order. A stream plus a single
                // draining task guarantees that; spawning a Task per buffer would not.
                let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )
                self.audioContinuation = audioContinuation

                // The recording is accumulated *inside* the ordered drain, not by spawning
                // a task per buffer. Unstructured tasks have no ordering guarantee, so
                // collecting them separately could assemble the replay audio out of order
                // and silently produce word-salad from the comparison.
                let comparing = isComparing
                self.feedTask = Task.detached(priority: .userInitiated) {
                    var recording: [AudioChunk] = []
                    for await chunk in audioStream {
                        if comparing { recording.append(chunk) }
                        await engine.feed(chunk)
                    }
                    return recording
                }

                // Start microphone capture immediately so audio buffer accumulation and HUD visualizer
                // react without waiting for speech model initialization.
                try capture.start(
                    outputFormat: format,
                    deviceUID: Settings.shared.selectedMicrophoneUID,
                    onBuffer: { chunk in
                        audioContinuation.yield(chunk)
                    },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.updateLevel(level) }
                    }
                )

                let chunks = try await engine.start()

                // If the user already released or stopped during spin-up:
                guard case .starting = self.state else {
                    if self.state == .finishing {
                        self.consumeTask = Task { @MainActor in
                            do {
                                for try await chunk in chunks {
                                    self.transcript = chunk.text
                                }
                            } catch {
                                self.fail(error.localizedDescription)
                            }
                        }
                    } else {
                        await self.teardown()
                    }
                    return
                }

                self.state = .listening
                if Settings.shared.soundEnabled { NSSound(named: "Tink")?.play() }

                self.consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunks {
                            self.transcript = chunk.text
                        }
                    } catch {
                        self.fail(error.localizedDescription)
                    }
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func endDictation() {
        // `.finishing` is "active", so without this a second press during processing would
        // run the whole tail again — re-reading `transcript` before the first pass cleared
        // it and pasting the same utterance twice. The window is wide: Parakeet transcribes
        // inside `finish()`, and smart cleanup adds up to 4s on top.
        guard state.isActive, state != .finishing else { return }
        state = .finishing
        level = 0
        releasedAt = Date()

        Task { @MainActor in
            // Hardware and USB audio buffering (e.g. Logitech C920) introduces ~100-150ms transit delay.
            // Brief flush wait ensures the last spoken syllable makes it into CoreAudio before stopping.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard self.state == .finishing else { return }
            self.capture.stop()

            // Drain every captured buffer into the engine before asking it to finalize,
            // or the tail of the utterance gets dropped.
            self.audioContinuation?.finish()
            self.audioContinuation = nil
            self.recorded = await self.feedTask?.value ?? []
            self.feedTask = nil

            let currentEngine = self.engine
            let currentConsume = self.consumeTask
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await currentEngine?.finish()
                    await currentConsume?.value
                }
                group.addTask {
                    // Generous 30s timeout for batch neural inference (WhisperKit / Parakeet)
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
                _ = await group.next()
                group.cancelAll()
            }

            consumeTask = nil
            engine = nil

            if isComparing {
                await runComparison()
                return
            }

            let raw = transcript
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .idle
                transcript = ""
                isCommandMode = false
                selectedTextForCommand = nil
                return
            }

            if isCommandMode {
                guard let selectedText = selectedTextForCommand, !selectedText.isEmpty else {
                    fail("Command Mode: No text selected")
                    isCommandMode = false
                    selectedTextForCommand = nil
                    return
                }

                let transformed = await CommandModeTransformer.transform(selectedText: selectedText, instruction: raw)
                let (output, corrections) = DictionaryStore.shared.corrector.apply(to: transformed)
                recordRun(text: "[CMD: \(raw)] \(output)", corrections: corrections)
                await restoreFocusIfNeeded()
                await TextInjector.insert(output)
                if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }
                state = .idle
                transcript = ""
                isCommandMode = false
                selectedTextForCommand = nil
                return
            }

            isCommandMode = false
            selectedTextForCommand = nil

            let appCtx = Settings.shared.appAwareStylesEnabled ? AppContextDetector.currentContext() : .standard

            var cleaned = Settings.shared.cleanupEnabled
                ? await activeFormatter.format(raw, context: appCtx)
                : raw

            if Settings.shared.snippetsEnabled, let expansion = SnippetStore.shared.expandSnippet(in: cleaned) {
                Log.speech.info("snippet expanded")
                cleaned = expansion
            }

            // The dictionary runs last, and runs regardless of the cleanup setting. Biasing
            // only raises the odds of the right word; this is the pass that guarantees it,
            // so it must not be something the user can accidentally switch off.
            let (output, corrections) = DictionaryStore.shared.corrector.apply(to: cleaned)
            if !corrections.isEmpty {
                Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
            }

            recordRun(text: output, corrections: corrections)
            AutoLearningEngine.shared.recordInjectedText(output, targetApp: lastExternalApp?.localizedName)
            await restoreFocusIfNeeded()
            await TextInjector.insert(output)
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }

            state = .idle
            transcript = ""
        }
    }

    private func restoreFocusIfNeeded() async {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier,
           let targetApp = lastExternalApp,
           !targetApp.isTerminated {
            Log.inject.info("Murmur is frontmost — restoring focus to \(targetApp.localizedName ?? "target app") before pasting")
            if let bundleId = targetApp.bundleIdentifier {
                let script = NSAppleScript(source: "tell application id \"\(bundleId)\" to activate")
                script?.executeAndReturnError(nil)
            }
            targetApp.activate()
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func cancelDictation() {
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil

        let engine = self.engine
        self.engine = nil
        Task { await engine?.finish() }

        state = .idle
        transcript = ""
        level = 0
        isCommandMode = false
        selectedTextForCommand = nil
    }

    private func teardown() async {
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        _ = await feedTask?.value
        feedTask = nil
        await engine?.finish()
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .idle
        isCommandMode = false
        selectedTextForCommand = nil
    }

    // MARK: - Helpers

    private func retainForComparison(_ chunk: AudioChunk) {
        guard isComparing else { return }
        recorded.append(chunk)
    }

    /// Replays the recording through every engine and files the results as one group.
    ///
    /// Nothing is injected in this mode — the point is to read the outputs side by side,
    /// and typing one of them into whatever had focus would be a surprise.
    private func runComparison() async {
        let chunks = recorded
        recorded.removeAll(keepingCapacity: false)

        guard !chunks.isEmpty, let holdStarted, let releasedAt else {
            state = .idle
            transcript = ""
            return
        }

        transcript = "Running both engines…"

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

        for result in results {
            Log.speech.info("""
                compare · \(result.engine, privacy: .public): \
                \(result.seconds, format: .fixed(precision: 2))s — \
                \(result.text, privacy: .public)
                """)
        }

        // Wispr Flow, if its hotkey was held for this same utterance. It transcribes in the
        // cloud, so its row lands after both local engines have already finished — the wait
        // happens here rather than blocking the rows above from appearing.
        if WisprReader.isInstalled {
            transcript = "Waiting for Wispr Flow…"
            if let wispr = await WisprReader.result(after: holdStarted, timeout: 8) {
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
                    \(wispr.text, privacy: .public)
                    """)
            } else {
                Log.speech.info("compare · Wispr Flow: no result (hotkey not held, or timed out)")
            }
        }

        self.holdStarted = nil
        self.releasedAt = nil
        isComparing = false
        state = .idle
        transcript = ""

        if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
    }

    /// Files the finished utterance for the dashboard.
    ///
    /// `processSeconds` is measured from key release, not from capture start — that's the
    /// wait the user actually experiences, and it's the only number on which a streaming
    /// engine and a batch engine can be compared honestly.
    private func recordRun(text: String, corrections: [AppliedCorrection] = []) {
        guard let holdStarted, let releasedAt else { return }
        RunLog.record(
            DictationRun(
                date: releasedAt,
                engine: engineName,
                audioSeconds: releasedAt.timeIntervalSince(holdStarted),
                processSeconds: Date().timeIntervalSince(releasedAt),
                text: text,
                corrections: corrections.isEmpty ? nil : corrections
            )
        )
        self.holdStarted = nil
        self.releasedAt = nil
    }

    /// Light smoothing so the waveform glides instead of strobing at buffer rate.
    private func updateLevel(_ new: Float) {
        level += (new - level) * 0.35
    }

    private func fail(_ message: String) {
        Log.app.error("\(message)")
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .error(message)
        level = 0

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            if case .error = state { state = .idle }
        }
    }
}
