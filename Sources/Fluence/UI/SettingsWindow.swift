import AppKit
import Carbon.HIToolbox
import FluenceCore
import SwiftUI

/// Settings window (Fluence 2026 Edition):
/// Ultra-clean, tabbed macOS settings inspired by Apple & Aqua Voice.
/// Stripped of all text walls, cognitive overload, and clutter.
///
/// FLU-11: Clement's three tabs as he made them, plus three for what main shipped since —
/// Texte (cleanup levels, styles, languages, dictionary helpers), Raccourcis, Réunions
/// (Notetaker) — and Confidentialité (history retention, recording limit) beside the
/// permissions.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @State private var selectedTab: SettingsTab = .general
    @State private var isRecordingPTT = false
    @State private var isRecordingCommand = false
    @State private var recordedModifiersString = ""
    @State private var localMonitor: Any?
    @State private var availableAudioDevices: [AudioInputDevice] = []
    @State private var hasAccessibility = Permissions.hasAccessibility
    @State private var hasMicrophone = Permissions.hasMicrophone

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "Général"
        case intelligence = "IA & Formatage"
        case text = "Texte"
        case shortcuts = "Raccourcis"
        case meetings = "Réunions"
        case permissions = "Confidentialité"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .intelligence: "sparkles"
            case .text: "textformat"
            case .shortcuts: "keyboard"
            case .meetings: "person.2.wave.2"
            case .permissions: "lock.shield"
            }
        }
    }

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            VStack(spacing: 16) {
                // Header with Aqua Voice Orb & Tab Navigation
                headerView

                // Tab Content
                ScrollView {
                    Group {
                        switch selectedTab {
                        case .general:
                            generalTab
                        case .intelligence:
                            intelligenceTab
                        case .text:
                            TextSettingsSection()
                        case .shortcuts:
                            ShortcutsSettingsSection(controller: controller)
                        case .meetings:
                            MeetingSettingsSection(model: .shared)
                        case .permissions:
                            permissionsTab
                        }
                    }
                    .transition(.opacity)
                    .padding(.bottom, DS.Space.snug)
                }
                .scrollIndicators(.automatic)
            }
            .padding(20)
        }
        .frame(width: DS.Window.settings.width, height: DS.Window.settings.height)
        .onAppear {
            refreshAudioDevices()
            hasAccessibility = Permissions.hasAccessibility
            hasMicrophone = Permissions.hasMicrophone
        }
        .onDisappear {
            stopRecordingKey()
        }
    }

    // MARK: - Header & Tab Bar

    private var headerView: some View {
        HStack {
            HStack(spacing: 9) {
                AquaOrbView(size: 22)
                Text("Réglages")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(DS.Color.ink)
            }

            Spacer()

            // Modern Pill Tab Switcher
            HStack(spacing: 3) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 10, weight: .medium))
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .foregroundStyle(selectedTab == tab ? DS.Color.ink : DS.Color.inkSecondary)
                        .background {
                            if selectedTab == tab {
                                Capsule()
                                    .fill(DS.Color.panel)
                                    .shadow(color: Color.black.opacity(0.06), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(DS.Color.well, in: Capsule())
        }
        .padding(.bottom, 2)
    }

    // MARK: - Tab 1: Général

    private var generalTab: some View {
        VStack(spacing: 12) {
            // Hotkey Card
            sectionCard {
                settingsRow(icon: "keyboard", title: "Raccourci Push-to-Talk") {
                    shortcutControl(isPTT: true)
                }
            }

            // Audio & Language Card
            sectionCard {
                settingsRow(icon: currentDeviceIcon, title: "Microphone") {
                    microphoneMenu
                }

                rowDivider

                settingsRow(
                    icon: "globe",
                    title: "Langue de dictée",
                    subtitle: settings.engine == .whisper ? "Français, Anglais ou Détection automatique" : nil
                ) {
                    // Auto: Whisper and Parakeet detect the language; Apple listens in the
                    // Mac's language. The other 23 languages are in the Texte tab.
                    Picker("", selection: $settings.dictationLanguage) {
                        Text("Français").tag(DictationLanguage.french)
                        Text("English").tag(DictationLanguage.english)
                        Text("Auto").tag(DictationLanguage.auto)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                    .onChange(of: settings.dictationLanguage) { _, lang in
                        Task.detached(priority: .utility) {
                            await AppleSpeechEngine.prewarm(locale: lang.locale)
                        }
                    }
                }

                rowDivider

                settingsRow(
                    icon: "arrow.triangle.swap",
                    title: "Bascule rapide de langue",
                    subtitle: settings.engine == .whisper ? "Français ⇄ English ⇄ Auto (⌥L)" : "Français ⇄ English (⌥L)"
                ) {
                    HStack(spacing: 6) {
                        Text("⌥L")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(DS.Color.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(DS.Color.seam, lineWidth: 1)
                            )
                        Button(settings.dictationLanguage.displayName + " actif") {
                            settings.toggleLanguage()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                rowDivider

                settingsRow(icon: "waveform", title: "Moteur vocal") {
                    Picker("", selection: $settings.engine) {
                        Text("Apple").tag(SpeechEngineChoice.apple)
                        Text("Whisper").tag(SpeechEngineChoice.whisper)
                        Text("Parakeet").tag(SpeechEngineChoice.parakeet)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                if settings.engine == .whisper {
                    rowDivider

                    settingsRow(
                        icon: "cpu",
                        title: "Modèle Whisper",
                        subtitle: WhisperModels.isDownloaded(variant: settings.whisperModel) ? "Installé sur le disque ✓" : "Téléchargement au 1er usage"
                    ) {
                        Picker("", selection: $settings.whisperModel) {
                            ForEach(WhisperModels.availableVariants) { v in
                                Text(v.displayName).tag(v.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }
                }
            }
        }
    }

    // MARK: - Tab 2: Intelligence & Formatage

    private var intelligenceTab: some View {
        VStack(spacing: 12) {
            // Clean Text Toggles
            sectionCard {
                settingsRow(
                    icon: "sparkles",
                    title: "Nettoyage IA local (LLM Apple Intelligence)",
                    subtitle: "Recommandé pour Apple Speech. Désactivé sur Whisper pour garantir une latence ultra-faible (< 0.8s)."
                ) {
                    Toggle("", isOn: $settings.smartCleanup)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!FoundationModelFormatter.isAvailable)
                }

                if settings.engine == .whisper {
                    rowDivider

                    settingsRow(
                        icon: "bolt",
                        title: "Post-traitement LLM sur Whisper",
                        subtitle: "Whisper ponctue déjà nativement. Activer ce LLM ajoute ~3.5s de délai."
                    ) {
                        Toggle("", isOn: $settings.smartCleanupOnWhisper)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(!FoundationModelFormatter.isAvailable)
                    }
                }

                rowDivider

                settingsRow(
                    icon: "scissors",
                    title: "Suppression des bégaiements & répétitions",
                    subtitle: "Élimine les 'euh', bégaiements et faux départs"
                ) {
                    Toggle("", isOn: $settings.cleanupEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                rowDivider

                settingsRow(icon: "chevron.left.forwardslash.chevron.right", title: "Formatage code & terminaux") {
                    Toggle("", isOn: $settings.appAwareStylesEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                rowDivider

                settingsRow(icon: "text.badge.plus", title: "Expansion des snippets vocaux") {
                    Toggle("", isOn: $settings.snippetsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            // Command Mode Card
            sectionCard {
                settingsRow(
                    icon: "wand.and.stars",
                    title: "Mode Commande (Réécriture IA)",
                    subtitle: FoundationModelFormatter.isAvailable ? nil : "Nécessite Apple Intelligence sur ce Mac"
                ) {
                    Toggle("", isOn: $settings.commandModeEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: settings.commandModeEnabled) { _, _ in
                            controller.reloadHotkey()
                        }
                }

                if settings.commandModeEnabled {
                    rowDivider

                    settingsRow(icon: "command", title: "Raccourci Commande") {
                        shortcutControl(isPTT: false)
                    }
                }
            }
        }
    }

    // MARK: - Tab 3: Permissions

    private var permissionsTab: some View {
        VStack(spacing: 12) {
            sectionCard {
                settingsRow(icon: "mic.fill", title: "Accès Microphone") {
                    if hasMicrophone {
                        statusBadge(text: "Autorisé", isOk: true)
                    } else {
                        Button("Autoriser…") {
                            Permissions.openMicrophoneSettings()
                        }
                        .font(DS.Font.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                rowDivider

                settingsRow(icon: "accessibility", title: "Accessibilité (Collage ⌘V)") {
                    if hasAccessibility {
                        statusBadge(text: "Autorisé", isOk: true)
                    } else {
                        Button("Autoriser…") {
                            Permissions.promptForAccessibility()
                            Permissions.openAccessibilitySettings()
                        }
                        .font(DS.Font.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                rowDivider

                settingsRow(icon: "bolt.fill", title: "Raccourcis Carbon") {
                    statusBadge(text: controller.isHotkeyActive ? "Actif" : "Inactif", isOk: controller.isHotkeyActive)
                }

                rowDivider

                settingsRow(icon: "checklist", title: "Assistant de configuration") {
                    Button("Ouvrir…") { OnboardingWindow.shared.show() }
                        .font(DS.Font.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            // History and recording limit (main, FLU-2 / FLU-3)
            sectionCard {
                settingsRow(
                    icon: "clock.arrow.circlepath",
                    title: "Garder l'historique",
                    subtitle: settings.historyRetention == .never
                        ? "Rien n'est écrit sur le disque"
                        : "Chiffré sur ce Mac, jamais sauvegardé"
                ) {
                    Picker("", selection: Binding(
                        get: { settings.historyRetention },
                        set: { retention in
                            settings.historyRetention = retention
                            RunLog.applyRetention()
                        }
                    )) {
                        ForEach(HistoryRetention.allCases, id: \.self) { retention in
                            Text(retention.displayName).tag(retention)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }

                rowDivider

                settingsRow(
                    icon: "timer",
                    title: "Durée maximale d'une dictée",
                    subtitle: "Au-delà, la dictée est terminée et tapée"
                ) {
                    Picker("", selection: $settings.maxRecordingMinutes) {
                        ForEach(Settings.recordingLimitChoices, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }

            if let problem = RunStore.shared.problem {
                Text(problem)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.fault)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            // Maintenance / Reset
            HStack {
                Spacer()
                Button("Réinitialiser l'autorisation Accessibilité") {
                    Permissions.resetAccessibilityTCC()
                    hasAccessibility = Permissions.hasAccessibility
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Controls & Helpers

    private func shortcutControl(isPTT: Bool) -> some View {
        let isRecording = isPTT ? isRecordingPTT : isRecordingCommand
        let key = isPTT ? settings.pushToTalkKey : settings.commandModeKey

        return HStack(spacing: 6) {
            Button {
                if isRecording {
                    stopRecordingKey()
                } else {
                    startRecordingKey(isPTT: isPTT)
                }
            } label: {
                HStack(spacing: 5) {
                    if isRecording {
                        ProgressView()
                            .controlSize(.small)
                        Text(recordedModifiersString.isEmpty ? "Tapez un combo…" : recordedModifiersString)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Color.accent)
                    } else {
                        Text(key.shortName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.Color.ink)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isRecording ? DS.Color.selection : DS.Color.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? DS.Color.accent : DS.Color.seam, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(PushToTalkKey.allCases) { item in
                    Button {
                        if isPTT {
                            settings.pushToTalkKey = item
                        } else {
                            settings.commandModeKey = item
                        }
                        controller.reloadHotkey()
                    } label: {
                        HStack {
                            Text(item.displayName)
                            if (isPTT ? settings.pushToTalkKey : settings.commandModeKey) == item {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Color.inkSecondary)
                    .frame(width: 20, height: 26)
                    .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(DS.Color.seam, lineWidth: 1)
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var microphoneMenu: some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    settings.selectedMicrophoneUID = "default"
                } label: {
                    HStack {
                        Text("Système (Par défaut)")
                        if isDefaultMicrophoneSelected { Image(systemName: "checkmark") }
                    }
                }

                if !availableAudioDevices.isEmpty {
                    Divider()
                    ForEach(availableAudioDevices) { dev in
                        Button {
                            settings.selectedMicrophoneUID = dev.id
                        } label: {
                            HStack {
                                Text(dev.name)
                                if settings.selectedMicrophoneUID == dev.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentDeviceDisplayName)
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(DS.Color.seam, lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 190, alignment: .trailing)

            Button {
                refreshAudioDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Color.inkSecondary)
                    .frame(width: 26, height: 26)
                    .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(DS.Color.seam, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Actualiser la liste des microphones")
        }
    }

    private func statusBadge(text: String, isOk: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isOk ? "checkmark" : "exclamationmark")
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(isOk ? DS.Color.meterGreen : DS.Color.meterAmber)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (isOk ? DS.Color.meterGreen : DS.Color.meterAmber).opacity(0.12),
            in: Capsule()
        )
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Color.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DS.Color.seam, lineWidth: 1)
                )
                .shadow(color: DS.Shadow.raised.color, radius: DS.Shadow.raised.radius, y: DS.Shadow.raised.y)
        )
    }

    private func settingsRow<Control: View>(
        icon: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Color.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(DS.Color.inkSecondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            control()
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var rowDivider: some View {
        Divider()
            .overlay(DS.Color.seam)
            .padding(.leading, 44)
    }

    // MARK: - Device State Helpers

    private var isDefaultMicrophoneSelected: Bool {
        settings.selectedMicrophoneUID == "default" || settings.selectedMicrophoneUID.isEmpty
    }

    private var currentDeviceDisplayName: String {
        if isDefaultMicrophoneSelected {
            return "Système (Par défaut)"
        }
        if let match = availableAudioDevices.first(where: { $0.id == settings.selectedMicrophoneUID }) {
            return match.name
        }
        return "Microphone externe"
    }

    private var currentDeviceIcon: String {
        if isDefaultMicrophoneSelected {
            return "laptopcomputer"
        }
        if let match = availableAudioDevices.first(where: { $0.id == settings.selectedMicrophoneUID }) {
            return match.iconName
        }
        return "mic.fill"
    }

    private func refreshAudioDevices() {
        availableAudioDevices = AudioDevices.availableInputDevices()
    }

    // MARK: - Key Recording Logic

    private func startRecordingKey(isPTT: Bool) {
        stopRecordingKey()
        recordedModifiersString = ""
        if isPTT {
            isRecordingPTT = true
            isRecordingCommand = false
        } else {
            isRecordingCommand = true
            isRecordingPTT = false
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown && Int(event.keyCode) == kVK_Escape {
                stopRecordingKey()
                return nil
            }
            if event.type == .flagsChanged {
                var syms: [String] = []
                if event.modifierFlags.contains(.control) { syms.append("⌃") }
                if event.modifierFlags.contains(.option) { syms.append("⌥") }
                if event.modifierFlags.contains(.command) { syms.append("⌘") }
                if event.modifierFlags.contains(.shift) { syms.append("⇧") }
                recordedModifiersString = syms.joined(separator: " ")
            }
            if let combo = PushToTalkKey.comboFrom(event: event) {
                applyRecordedKey(combo, isPTT: isPTT)
                return nil
            }
            return event
        }
    }

    private func applyRecordedKey(_ key: PushToTalkKey, isPTT: Bool) {
        if isPTT {
            settings.pushToTalkKey = key
            if settings.commandModeKey == key {
                if let alt = PushToTalkKey.allCases.first(where: { $0 != key }) {
                    settings.commandModeKey = alt
                }
            }
        } else {
            settings.commandModeKey = key
        }
        controller.reloadHotkey()
        stopRecordingKey()
    }

    private func stopRecordingKey() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isRecordingPTT = false
        isRecordingCommand = false
        recordedModifiersString = ""
    }
}
