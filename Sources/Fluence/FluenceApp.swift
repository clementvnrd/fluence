import AppKit
import FluenceCore
import SwiftUI

@main
struct FluenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // FLU-27: a second copy hands over to the running one before anything starts.
        SingleInstance.handOverIfRunning()
    }

    var body: some Scene {
        // A `Window` rather than a `WindowGroup`: Fluence has exactly one main
        // panel, and letting ⌘N spawn a second copy of it makes no sense.
        // FLU-12: a sidebar window (navigation B) — the sidebar runs under the hidden title
        // bar, the traffic lights float over it. The meetings library lives here too.
        Window(AppDelegate.mainTitle, id: "main") {
            MainWindow(controller: delegate.controller)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: DS.Window.main.width, height: DS.Window.main.height)
        .windowResizability(.contentMinSize)
        .commands {
            // ⌘N would create a second main window, which cannot exist: leave "New" empty.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                // FLU-26: under « À propos de Fluence », where macOS apps keep it.
                UpdateMenuButton()
                Button("Afficher le fichier du dictionnaire") {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
            MeetingsCommands()
        }

        // Clement's quick correction window: fix the last dictation and teach the dictionary.
        Window(AppDelegate.correctionTitle, id: "correction") {
            CorrectionQuickSheet()
        }
        .defaultSize(width: 480, height: 320)
        .windowResizability(.contentSize)

        // Spelled with its module: inside this app, a bare `Settings` is our own preferences
        // type, which shadows SwiftUI's scene.
        SwiftUI.Settings {
            SettingsWindow(controller: delegate.controller)
        }
        .windowStyle(.hiddenTitleBar)

        // Where Fluence lives with its window closed (FLU-59): status, the settings that matter
        // while working elsewhere, and « Ouvrir Fluence ».
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            // MARK: Notetaker (capture) — the icon shows a meeting is being recorded.
            Image(systemName: MeetingController.shared.isRecording
                ? "record.circle"
                : (delegate.controller.state.isActive ? "waveform.circle.fill" : "waveform"))
        }

        Window(AppDelegate.comparisonTitle, id: "comparison") {
            ComparisonWindow(controller: delegate.controller)
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Window titles, also used to find the windows from AppKit.
    static let mainTitle = "Fluence"
    static let correctionTitle = "Auto-Apprentissage"
    static let comparisonTitle = "Comparaison des moteurs"

    let controller = DictationController()
    /// A quit is waiting for a meeting to stop and save (FLU-54).
    private var quitPending = false
    private var hud: HUDPanel?
    private var previewHUD: HUDPanel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // FLU-59: Dock icon, app menu and ordinary windows while a window is open; menu bar
        // only once the last one is closed, and from the start when the Mac launched us at login
        // (FLU-58). Dictating into another app still keeps that app focused: the HUD panel is
        // non-activating whatever the policy says.
        let inBackground = AppPresence.startsInBackground
        AppPresence.shared.start(inBackground: inBackground)

        hud = HUDPanel(controller: controller)
        // MARK: FLU-12 — dev-only HUD preview for screenshots, under
        // FLUENCE_SUPPORT_DIRECTORY only (see `HUDPreview`).
        if let preview = HUDPreview.requested {
            previewHUD = HUDPanel(controller: controller, preview: preview)
            previewHUD?.present()
        }

        controller.activate()
        if !Permissions.hasAccessibility {
            // Carbon shortcuts already work; the event tap (Esc, ⌃⌘V, modifier-only
            // shortcuts) can only be created once the user grants Accessibility, and there's
            // no system notification when that happens, so poll until it does.
            // MARK: FLU-5 input — no bare system prompt here: the onboarding window below
            // explains Accessibility and raises the prompt from its button.
            retryActivation()
        }
        // MARK: FLU-5 input
        // Not at login: a window nobody asked for, when the menu bar already lists what is missing.
        if (OnboardingWindow.isNeeded && !inBackground) || DevPreview.onboardingStep != nil { OnboardingWindow.shared.show() }

        // Reads (and on first run after the update, seals and replaces) the history off the
        // main thread, then applies the retention setting.
        RunLog.start()
        // FLU-12, dev only: synthetic data for screenshots (after the history load is queued,
        // so the seeded runs land after it).
        ScreenshotSeed.applyIfRequested()
        // MARK: FLU-5 text — snippets are sealed like history; open them now, not on the
        // first dictation, which would otherwise run without them.
        _ = SnippetStore.shared

        // The selected engine's models take seconds to load, and that cost lands on whichever
        // dictation touches them first. Warm them in the background — only when they're
        // already downloaded; nothing is downloaded behind the user's back.
        if Settings.shared.compareMode, ParakeetModels.isDownloaded {
            Task.detached(priority: .utility) {
                _ = try? await ParakeetModels.shared.manager()
            }
        }
        Settings.shared.prewarmCurrentEngine()

        // Each `make install` relaunches the app and its windows are lost; without this the
        // comparison window would disappear on every rebuild.
        if !inBackground, UserDefaults.standard.bool(forKey: "comparisonWindowOpen") {
            Task { @MainActor in
                // Give SwiftUI time to create the scene's window, or there is no title to find.
                try? await Task.sleep(for: .milliseconds(400))
                Self.showComparisonWindow()
            }
        }

        watchDictationState()

        // FLU-26: in-app updates, held back while a dictation or a meeting is in progress.
        AppUpdater.shared.start()
        observeBusy()

        // MARK: Notetaker (capture)
        // Watches for calls and offers to take notes; nothing records without the user.
        MeetingController.shared.start()
        MeetingController.shared.previewRecordingPanelIfRequested()
        // MARK: end Notetaker (capture)

        // MARK: Notetaker (library) — notes on `.meetingFinalized`, retention purge.
        NotetakerNotes.launch()

        Log.app.info("Fluence ready — hold \(Settings.shared.pushToTalkKey.displayName, privacy: .public) to dictate")

        DevPreview.snapshotIfRequested()

        // Clement's build brings the main window forward at launch — except at login, where
        // Fluence stays in the menu bar until it is opened.
        if !inBackground {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                AppPresence.mainWindow?.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppPresence.shared.reopenMainWindow() }
        return true
    }

    /// `fluence://show` raises the comparison window; `fluence://correct` the correction
    /// window.
    ///
    /// Nothing destructive is reachable from here on purpose: any app, and any web page
    /// after one browser prompt, can open a custom-scheme URL. The old `clear` action wiped
    /// the whole history that way, with no confirmation.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "fluence" {
            switch url.host {
            case "show": Self.showComparisonWindow()
            case "correct": Self.showWindow(titled: Self.correctionTitle)
            default: break
            }
        }
    }

    /// Goes through AppKit, not SwiftUI's `openWindow` (a view-only environment value), so
    /// the delegate and the URL handler can call it too.
    static func showComparisonWindow() {
        showWindow(titled: comparisonTitle)
    }

    private static func showWindow(titled title: String) {
        AppPresence.shared.becomeRegular()
        NSApp.windows.first { $0.title == title }?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// FLU-54: a meeting is recorded once. Quitting during one asks « Arrêter et enregistrer
    /// la réunion ? », then stops and saves it before Fluence goes; a log out, restart or
    /// shut down does the same without asking (`QuitPlan`). Outside quit events are not
    /// refused (FLU-64): they get the same question, and *Annuler* is the user's choice.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second ⌘Q while the first waits: the first one's answer still ends the app.
        if quitPending { return .terminateCancel }
        let meetings = MeetingController.shared
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(QuitPlan.quitReasonKeyword))?.enumCodeValue
        let origin = QuitPlan.origin(quitReason: reason)
        switch QuitPlan.decide(recording: meetings.isRecording, origin: origin) {
        case .quitNow:
            return .terminateNow
        case .ask:
            guard confirmStoppingMeeting() else {
                Log.app.info("quit cancelled: a meeting is recording")
                return .terminateCancel
            }
        case .stopAndSave:
            break
        }
        quitPending = true
        Log.app.info("quit: stopping the meeting first (\(origin == .system ? "system" : "user", privacy: .public))")
        Task { @MainActor in
            await meetings.stopForQuit(origin: origin)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// « Arrêter et enregistrer la réunion ? » — true for *Arrêter et quitter*.
    private func confirmStoppingMeeting() -> Bool {
        // From the menu bar Fluence may have no window and no Dock icon: bring it forward,
        // or the question opens behind the call.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = QuitPlan.question
        alert.informativeText = QuitPlan.detail
        alert.addButton(withTitle: QuitPlan.confirmTitle)
        alert.addButton(withTitle: QuitPlan.cancelTitle).keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) {
        // FLU-54: normally stopped and saved above already; this covers a termination that
        // skipped the question. The meeting's marker stays, the next launch finishes it.
        MeetingController.shared.saveBeforeExit()
        let isOpen = NSApp.windows.contains { $0.title == Self.comparisonTitle && $0.isVisible }
        UserDefaults.standard.set(isOpen, forKey: "comparisonWindowOpen")
        controller.deactivate()
        // Belt and braces: quitting mid-comparison must not leave Wispr Flow's key held down,
        // or Wispr keeps recording — and uploading — after Fluence is gone.
        #if !FLUENCE_WITHOUT_WISPR
        WisprTrigger.release()
        #endif
    }

    /// Puts the HUD on screen while the dictation state wants it and takes it away after.
    /// FLU-12: also while the auto-learn offer is on the capsule.
    private func watchDictationState() {
        withObservationTracking {
            _ = controller.state
            _ = LearnedWords.shared.spotlight
        } onChange: { [weak self] in
            // Called before the new value is stored, maybe off the main actor: read it after.
            Task { @MainActor in
                guard let self else { return }
                if self.controller.state.showsHUD || LearnedWords.shared.spotlight != nil {
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                // Observation fires once; ask again for the next change.
                self.watchDictationState()
            }
        }
    }

    /// Tells the updater when a dictation or a meeting (recording or being processed) is in
    /// progress, so no update question or relaunch lands in the middle of one (FLU-26).
    private func observeBusy() {
        // Read under tracking, written outside it: the updater's own reads (when it offers
        // an update as the recording ends) must not become part of what is observed here.
        let busy = withObservationTracking {
            UpdatePolicy.isBusy(
                dictating: controller.state.isActive,
                meetingInProgress: MeetingController.shared.isBusy
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeBusy() }
        }
        if AppUpdater.shared.isBusy != busy { AppUpdater.shared.isBusy = busy }
    }

    private func retryActivation() {
        Task { @MainActor in
            while !Permissions.hasAccessibility {
                try? await Task.sleep(for: .seconds(1))
            }
            controller.reloadHotkey()
            Log.app.info("Accessibility granted — event tap armed")
        }
    }
}

/// « Rechercher des mises à jour… », or « Installer Fluence x.y.z… » once a new version is
/// downloaded (FLU-26). Hidden in a build without an update feed.
private struct UpdateMenuButton: View {
    private let updater = AppUpdater.shared

    var body: some View {
        if updater.isRunning {
            Button(updater.readyVersion.map { "Installer Fluence \($0)…" } ?? "Rechercher des mises à jour…") {
                updater.checkNow()
            }
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

    private var parakeetItemTitle: String {
        if isPreloadingParakeet { return "Chargement des modèles Parakeet…" }
        // Ask the disk: the models may be there without this menu having fetched them.
        return parakeetOnDisk ? "Modèles Parakeet installés ✓" : "Télécharger les modèles Parakeet…"
    }

    private func prepareParakeet() {
        guard !isPreloadingParakeet else { return }
        isPreloadingParakeet = true
        Task {
            do {
                // Loads the models, fetching them first (some 600 MB) when they are missing.
                _ = try await ParakeetModels.shared.manager()
                parakeetOnDisk = ParakeetModels.isDownloaded
            } catch {
                Log.speech.error("Parakeet models could not be prepared: \(error.localizedDescription)")
            }
            isPreloadingParakeet = false
        }
    }

    var body: some View {
        // FLU-59: the way back to the app from the menu bar, first and plain.
        Button {
            AppPresence.shared.showMainWindow(openWindow: openWindow)
        } label: {
            Label("Ouvrir Fluence", systemImage: "macwindow")
        }

        Divider()

        Button(controller.state.isActive ? "⏹ Arrêter la dictée" : "Démarrer la dictée") {
            if controller.state.isActive {
                controller.stopButtonRecording()
            } else {
                controller.startButtonRecording()
            }
        }

        Text("Maintenir \(settings.pushToTalkKey.shortName) pour dicter")

        Divider()

        Picker("Langue", selection: Binding(
            get: { settings.dictationLanguage },
            set: { language in
                settings.dictationLanguage = language
                settings.prewarmCurrentEngine()
            }
        )) {
            Text("Français").tag(DictationLanguage.french)
            Text("English").tag(DictationLanguage.english)
            Text("Auto").tag(DictationLanguage.auto)
            if ![.french, .english, .auto].contains(settings.dictationLanguage) {
                Text(settings.dictationLanguage.displayName).tag(settings.dictationLanguage)
            }
        }

        Button("Basculer la langue (\(settings.dictationLanguage.shortDisplay))") {
            settings.toggleLanguage()
        }
        .keyboardShortcut("l", modifiers: .option)

        Picker("Raccourci Push-to-talk", selection: Binding(
            get: { settings.pushToTalkKey },
            set: { key in
                settings.pushToTalkKey = key
                // The event tap listens for one key; move it to the new one.
                controller.reloadHotkey()
            }
        )) {
            if !PushToTalkKey.allCases.contains(settings.pushToTalkKey) {
                Text(settings.pushToTalkKey.displayName).tag(settings.pushToTalkKey)
            }
            ForEach(PushToTalkKey.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }

        Toggle("Mode comparaison", isOn: $settings.compareMode)

        if !settings.compareMode {
            Picker("Moteur", selection: $settings.engine) {
                ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
        }

        // MARK: FLU-5 text
        Picker("Nettoyage", selection: $settings.cleanupLevel) {
            ForEach(CleanupLevel.allCases, id: \.self) { level in
                Text(level.title).tag(level)
            }
        }
        if settings.cleanupLevel.usesModel, let reason = FoundationModelFormatter.unavailableReason {
            Text(reason).font(.caption)
        }
        // MARK: end FLU-5 text

        Toggle("Formatage code & terminaux", isOn: $settings.appAwareStylesEnabled)
        Toggle("Snippets vocaux", isOn: $settings.snippetsEnabled)
        Toggle("Mode Commande (\(settings.commandModeKey.shortName))", isOn: Binding(
            get: { settings.commandModeEnabled },
            set: { on in
                settings.commandModeEnabled = on
                controller.reloadHotkey()
            }
        ))
        Toggle("Son", isOn: $settings.soundEnabled)

        Divider()

        // MARK: Notetaker (capture)
        MeetingMenuItems(controller: MeetingController.shared)
        Divider()
        // MARK: end Notetaker (capture)

        Button("Corriger la dernière dictée…") {
            AppPresence.shared.becomeRegular()
            openWindow(id: "correction")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(.delete, modifiers: .option)

        Button("Afficher la comparaison des moteurs") {
            AppPresence.shared.becomeRegular()
            openWindow(id: "comparison")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("d")

        // MARK: Notetaker (library)
        MeetingsMenuButton()

        // Downloading ~600 MB on the first hold would look like a hang, so offer to do it
        // beforehand, when the user asks for it.
        if settings.engine == .parakeet {
            Button(parakeetItemTitle) { prepareParakeet() }
                .disabled(isPreloadingParakeet || parakeetOnDisk)
        }

        if settings.engine == .whisper {
            let isLoaded = WhisperModels.isDownloaded(variant: settings.whisperModel)
            Button(isLoaded ? "Modèle Whisper prêt ✓" : "Télécharger le modèle Whisper…") {
                let model = settings.whisperModel
                Task.detached(priority: .utility) {
                    try? await WhisperModels.shared.prepare(variant: model)
                }
            }
            .disabled(isLoaded)
        }

        if let problem = RunStore.shared.problem {
            Text(problem).font(.caption)
        }

        // MARK: FLU-5 input
        Button("Configurer Fluence…") { OnboardingWindow.shared.show() }
        UpdateMenuButton()

        if !Permissions.hasAccessibility {
            Button("Autoriser l'Accessibilité…") { Permissions.openAccessibilitySettings() }
        }
        if !Permissions.hasMicrophone {
            Button("Autoriser le micro…") { Permissions.openMicrophoneSettings() }
        }

        Divider()

        Button("Réglages…") {
            AppPresence.shared.becomeRegular()
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quitter Fluence") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
