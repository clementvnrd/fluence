import AppKit
@preconcurrency import AVFoundation
import SwiftUI

@main
struct MurmurYouTubeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window. A `Window` rather than a `WindowGroup`: this app has one front
        // panel, and letting ⌘N spawn a second copy of a tape deck makes no sense.
        Window("Fluence", id: "main") {
            MainWindow(controller: delegate.controller)
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Reveal Dictionary File") {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
                Button("Reveal Snippets File") {
                    NSWorkspace.shared.activateFileViewerSelecting([SnippetStore.shared.fileURL])
                }
            }
        }

        Window("Auto-Apprentissage", id: "correction") {
            CorrectionQuickSheet()
        }
        .defaultSize(width: 480, height: 320)
        .windowResizability(.contentSize)

        // Fully qualified: this app has its own `Settings` type, which otherwise shadows
        // SwiftUI's settings scene.
        SwiftUI.Settings {
            SettingsWindow(controller: delegate.controller)
        }

        // Secondary now: status and the hotkey while you're working in another app.
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.state.isActive ? "waveform.circle.fill" : "waveform")
        }

        Window("Engine comparison", id: "comparison") {
            ComparisonWindow(controller: delegate.controller)
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    private var hud: HUDPanel?
    private var stateObservation: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let idx = CommandLine.arguments.firstIndex(of: "--test-whisper"),
           idx + 1 < CommandLine.arguments.count {
            let wavPath = CommandLine.arguments[idx + 1]
            Task {
                await Self.runWhisperTest(wavPath: wavPath)
                exit(0)
            }
            return
        }
        // A regular app now: dock icon, app menu, standard windows. The HUD is still a
        // non-activating panel, so dictating into another app never steals its focus — that
        // property belongs to the panel, not to the activation policy.
        NSApp.setActivationPolicy(.regular)

        hud = HUDPanel(controller: controller)

        controller.activate()

        if !Permissions.hasAccessibility {
            Permissions.promptForAccessibility()
            // Poll until the user grants Accessibility in System Settings, then rearm
            retryActivation()
        }

        // Write the dashboard up front so the menu item always opens something, even
        // before the first dictation.
        RunLog.regenerate()

        // Prewarm active speech engine (Whisper, Parakeet, or Apple) so first keypress is immediate
        Settings.shared.prewarmCurrentEngine()

        if UserDefaults.standard.bool(forKey: "comparisonWindowOpen") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                Self.showComparisonWindow()
            }
        }

        observeState()
        Log.app.info("Fluence ready — hold \(Settings.shared.pushToTalkKey.displayName) to dictate")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if let window = NSApp.windows.first(where: { $0.title == "Fluence" }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = NSApp.windows.first(where: { $0.title == "Fluence" }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    /// `fluence://clear`, `fluence://show`, `fluence://correct`
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "fluence" || url.scheme == "murmuryt" {
            switch url.host {
            case "clear":
                RunLog.clear()
                RunStore.shared.reload()
            case "show":
                Self.showComparisonWindow()
            case "correct":
                openCorrectionWindow()
            default:
                break
            }
        }
    }

    private func openCorrectionWindow() {
        if let window = NSApp.windows.first(where: { $0.title == "Auto-Apprentissage" }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Raises the comparison window without needing SwiftUI's `openWindow` environment
    /// value — usable from the app delegate and from a URL handler.
    static func showComparisonWindow() {
        RunStore.shared.reload()
        if let existing = NSApp.windows.first(where: { $0.title == "Engine comparison" }) {
            existing.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        let isOpen = NSApp.windows.contains { $0.title == "Engine comparison" && $0.isVisible }
        UserDefaults.standard.set(isOpen, forKey: "comparisonWindowOpen")
        controller.deactivate()
    }

    /// Shows and hides the HUD in step with the controller's state.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.controller.state.isActive {
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                self.observeState()
            }
        }
    }

    private func retryActivation() {
        Task { @MainActor in
            while !Permissions.hasAccessibility {
                try? await Task.sleep(for: .seconds(1))
            }
            Log.app.info("Accessibility granted — hotkey and HID injection armed")
            controller.reloadHotkey()
        }
    }

    private static func runWhisperTest(wavPath: String) async {
        print("--- RUNNING WHISPER AUDIO TEST ---")
        let url = URL(fileURLWithPath: wavPath)
        do {
            let file = try AVAudioFile(forReading: url)
            let frameCount = AVAudioFrameCount(file.length)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
                print("Failed to allocate audio buffer")
                return
            }
            try file.read(into: buffer)

            var samples: [Float] = []
            if file.processingFormat == format, let channelData = buffer.floatChannelData {
                samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            } else if let converter = AVAudioConverter(from: file.processingFormat, to: format) {
                let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * 16_000.0 / file.processingFormat.sampleRate)
                if let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outFrames) {
                    var error: NSError?
                    converter.convert(to: outBuffer, error: &error) { _, status in
                        status.pointee = .haveData
                        return buffer
                    }
                    if let channelData = outBuffer.floatChannelData {
                        samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
                    }
                }
            }

            print("Loaded audio: \(samples.count) samples (\(Double(samples.count) / 16_000.0)s)")
            let model = Settings.shared.whisperModel
            print("Testing with model: \(model)")

            // Test 1: Explicit French ("fr")
            let textFr = try await WhisperModels.shared.transcribe(
                samples: samples,
                variant: model,
                language: "fr"
            )
            print("WHISPER_RESULT_EXPLICIT_FR: \"\(textFr)\"")

            // Test 2: Auto-detect (language: nil, detectLanguage: true)
            let textAuto = try await WhisperModels.shared.transcribe(
                samples: samples,
                variant: model,
                language: nil
            )
            print("WHISPER_RESULT_AUTO: \"\(textAuto)\"")
            print("--- WHISPER AUDIO TEST COMPLETE ---")
        } catch {
            print("Whisper test error: \(error)")
        }
    }
}

private struct MenuContent: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isPreloadingParakeet = false
    @State private var parakeetOnDisk = ParakeetModels.isDownloaded

    private var parakeetStatus: String {
        if isPreloadingParakeet { return "Loading Parakeet models…" }
        // Reflects what's actually on disk, not just what this menu instance has done.
        return parakeetOnDisk ? "Parakeet models installed ✓" : "Download Parakeet models…"
    }

    private func preloadParakeet() {
        guard !isPreloadingParakeet else { return }
        isPreloadingParakeet = true
        Task {
            do {
                _ = try await ParakeetModels.shared.manager()
                parakeetOnDisk = ParakeetModels.isDownloaded
            } catch {
                Log.speech.error("Parakeet preload failed: \(error.localizedDescription)")
            }
            isPreloadingParakeet = false
        }
    }

    var body: some View {
        Button(controller.state.isActive ? "⏹ Arrêter la dictée" : "🔴 Démarrer la dictée") {
            if controller.state.isActive {
                controller.stopButtonRecording()
            } else {
                controller.startButtonRecording()
            }
        }

        Text("Maintenir \(settings.pushToTalkKey.shortName) pour dicter")

        Divider()

        if settings.engine == .whisper {
            Picker("Langue", selection: Binding(
                get: { settings.language },
                set: { lang in settings.language = lang }
            )) {
                Text("Français").tag(DictationLanguage.french)
                Text("English").tag(DictationLanguage.english)
                Text("Auto (FR / EN)").tag(DictationLanguage.auto)
            }

            Button("Basculer la langue (\(settings.language.shortDisplay))") {
                settings.toggleLanguage()
            }
            .keyboardShortcut("l", modifiers: .option)
        } else {
            Picker("Langue", selection: Binding(
                get: { settings.language },
                set: { lang in
                    settings.language = lang
                    Task.detached(priority: .utility) {
                        await AppleSpeechEngine.prewarm(locale: lang.locale)
                    }
                }
            )) {
                ForEach(DictationLanguage.allCases.filter { $0 != .auto }, id: \.self) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }

            Button("Basculer la langue (FR / EN)") {
                settings.toggleLanguage()
            }
            .keyboardShortcut("l", modifiers: .option)
        }

        Picker("Touche Push-to-talk", selection: Binding(
            get: { settings.pushToTalkKey },
            set: { key in
                settings.pushToTalkKey = key
                controller.reloadHotkey()
            }
        )) {
            if !PushToTalkKey.allCases.contains(where: { $0.rawValue == settings.pushToTalkKey.rawValue }) {
                Text(settings.pushToTalkKey.displayName).tag(settings.pushToTalkKey)
            }
            ForEach(PushToTalkKey.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }

        Toggle("Compare mode (both engines)", isOn: $settings.compareMode)

        if !settings.compareMode {
            Picker("Engine", selection: $settings.engine) {
                ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
        }

        Toggle("Clean up text", isOn: $settings.cleanupEnabled)

        if settings.cleanupEnabled {
            Toggle("Smart cleanup (on-device AI)", isOn: $settings.smartCleanup)
                .disabled(!FoundationModelFormatter.isAvailable)
            if let reason = FoundationModelFormatter.unavailableReason {
                Text(reason).font(.caption)
            }
        }

        Toggle("App-aware formatting", isOn: $settings.appAwareStylesEnabled)
        Toggle("Voice snippets", isOn: $settings.snippetsEnabled)
        Toggle("Command mode (\(settings.commandModeKey.displayName))", isOn: $settings.commandModeEnabled)
            .onChange(of: settings.commandModeEnabled) { _, _ in
                controller.reloadHotkey()
            }

        Toggle("Sound", isOn: $settings.soundEnabled)

        Divider()

        Button("Corriger la dernière dictée…") {
            openWindow(id: "correction")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(.delete, modifiers: .option)

        Button("Ouvrir la fenêtre principale") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("m")

        Button("Show comparison window") {
            RunStore.shared.reload()
            openWindow(id: "comparison")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("d")

        // Downloading ~470 MB on the first hold would look like a hang, so offer to do it
        // deliberately instead.
        if settings.engine == .parakeet {
            Button(parakeetStatus) { preloadParakeet() }
                .disabled(isPreloadingParakeet || parakeetOnDisk)
        }

        if settings.engine == .whisper {
            let isLoaded = WhisperModels.isDownloaded(variant: settings.whisperModel)
            Button(isLoaded ? "Modèle Whisper prêt ✓" : "Télécharger le modèle Whisper…") {
                Task {
                    _ = try? await WhisperModels.shared.prepare(variant: settings.whisperModel)
                }
            }
            .disabled(isLoaded)
        }

        if !Permissions.hasAccessibility {
            Button("Grant Accessibility…") { Permissions.openAccessibilitySettings() }
        }
        if !Permissions.hasMicrophone {
            Button("Grant Microphone…") { Permissions.openMicrophoneSettings() }
        }

        Divider()

        Button("Réglages…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quitter Fluence") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
