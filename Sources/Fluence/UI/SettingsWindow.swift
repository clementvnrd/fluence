import AppKit
import Carbon.HIToolbox
import FluenceCore
import SwiftUI

/// Réglages (FLU-12, mock-ups 08 and 09): a section list on the left, the section on the
/// right. Every setting of the earlier tabbed window is here — see
/// `docs/DESIGN-FLU-12.md` for the map from old tab to new section.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    @State private var selection: SettingsSection = .dictation

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Color.clear.frame(height: DS.Window.titleBarClearance)
                HStack(spacing: 9) {
                    AquaOrbView(size: 22)
                    Text("Réglages").font(.system(size: 16, weight: .bold)).foregroundStyle(DS.Color.ink)
                }
                .padding(.leading, 10)
                .padding(.bottom, DS.Space.wide)
                ForEach(SettingsSection.allCases) { section in
                    SidebarItem(systemImage: section.symbol, title: section.title, isSelected: selection == section) {
                        selection = section
                    }
                }
                Spacer()
            }
            .padding(.horizontal, DS.Space.base)
            .frame(width: DS.Window.settingsSidebar)
            .frame(maxHeight: .infinity)
            .background(DS.Color.chassis)
            .overlay(alignment: .trailing) { Rectangle().fill(DS.Color.seam).frame(width: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.base) {
                    ContentTitle(title: selection.title, subtitle: selection.subtitle)
                        .padding(.bottom, DS.Space.snug)
                    switch selection {
                    case .dictation: DictationSettingsSection(controller: controller)
                    case .transcription: TranscriptionSettingsSection()
                    case .text: TextSettingsSection()
                    case .meetings: MeetingSettingsSection(model: .shared)
                    case .privacy: PrivacySettingsSection(controller: controller, model: .shared)
                    case .about: AboutSettingsSection()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 30)
                .padding(.bottom, DS.Space.panel)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Color.chassis.opacity(0.6))
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: DS.Window.settings.width, height: DS.Window.settings.height)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case dictation, transcription, text, meetings, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictée"
        case .transcription: "Transcription"
        case .text: "Texte"
        case .meetings: "Réunions"
        case .privacy: "Confidentialité"
        case .about: "À propos"
        }
    }

    var subtitle: String {
        switch self {
        case .dictation: "Comment vous dictez : raccourcis, micro et gestes."
        case .transcription: "Le moteur qui transforme votre voix en texte, sur ce Mac."
        case .text: "Ce que Fluence fait du texte avant de le coller."
        case .meetings: "Repérer les appels, nommer les intervenants, prévenir les participants."
        case .privacy: "Ce que Fluence garde, combien de temps, et comment l'effacer."
        case .about: "Fluence, sa version et ce qu'il fait de vos données."
        }
    }

    var symbol: String {
        switch self {
        case .dictation: "mic"
        case .transcription: "waveform"
        case .text: "textformat"
        case .meetings: "person.2"
        case .privacy: "lock.shield"
        case .about: "info.circle"
        }
    }
}

// MARK: - Dictée

struct DictationSettingsSection: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        SectionCard {
            SettingsRow(systemImage: "keyboard", title: "Raccourci de dictée", subtitle: "Maintenez pour dicter ; touchez pour les mains libres.") {
                ShortcutRecorder(controller: controller, isCommand: false)
            }
            RowDivider()
            SettingsRow(systemImage: microphoneIcon, title: "Microphone") {
                microphoneMenu
            }
            RowDivider()
            SettingsRow(systemImage: "timer", title: "Durée maximale d'une dictée", subtitle: "Au-delà, la dictée est terminée et tapée.") {
                PillTabs(
                    options: Settings.recordingLimitChoices,
                    title: { "\($0)\(FrenchFormat.space)min" },
                    selection: settings.maxRecordingMinutes,
                    small: true
                ) { settings.maxRecordingMinutes = $0 }
            }
            RowDivider()
            SettingsRow(systemImage: "speaker.wave.2", title: "Son", subtitle: "Un léger signal au début et à la fin de la dictée.") {
                RowToggle(isOn: $settings.soundEnabled)
            }
        }

        SectionCard {
            SettingsRow(
                systemImage: "wand.and.stars",
                title: "Mode Commande",
                subtitle: FoundationModelFormatter.isAvailable
                    ? "Sélectionnez un texte, maintenez le raccourci et dites comment le réécrire."
                    : "Nécessite Apple Intelligence sur ce Mac."
            ) {
                RowToggle(isOn: Binding(
                    get: { settings.commandModeEnabled },
                    set: { on in
                        settings.commandModeEnabled = on
                        controller.reloadHotkey()
                    }
                ))
            }
            if settings.commandModeEnabled {
                RowDivider()
                SettingsRow(systemImage: "command", title: "Raccourci du Mode Commande") {
                    ShortcutRecorder(controller: controller, isCommand: true)
                }
            }
            RowDivider()
            SettingsRow(
                systemImage: "doc.on.clipboard",
                title: "⌃⌘V colle, ⌃⌘C copie la dernière transcription",
                subtitle: "Gardée en mémoire seulement, jusqu'à ce que vous quittiez."
            ) {
                RowToggle(isOn: Binding(
                    get: { settings.lastTranscriptShortcuts },
                    set: { on in
                        settings.lastTranscriptShortcuts = on
                        controller.reloadHotkey()
                    }
                ))
            }
            RowDivider()
            SettingsRow(systemImage: "arrow.triangle.swap", title: "Bascule rapide de langue", subtitle: settings.engine == .whisper ? "Français ⇄ English ⇄ Auto" : "Français ⇄ English") {
                HStack(spacing: 6) {
                    KeyCap(text: "⌥L")
                    CapButton(title: settings.dictationLanguage.displayName, height: 24) { settings.toggleLanguage() }
                }
            }
        }

        SectionCard {
            SettingsRow(systemImage: "hand.tap", title: "Gestes", subtitle: "Ce que font vos raccourcis, partout sur le Mac.") { EmptyView() }
            ShortcutLegend()
                .padding(.leading, 46)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            if !controller.hasEventTap {
                RowNote(text: "Échap, ⌃⌘V / ⌃⌘C et les raccourcis sans touche (⌃ ⌥) ont besoin de l'autorisation Accessibilité. Les raccourcis avec une touche (⌥ Espace) marchent sans elle.")
            }
        }
        .onAppear { devices = AudioDevices.availableInputDevices() }
    }

    private var isDefaultMicrophone: Bool {
        settings.selectedMicrophoneUID == "default" || settings.selectedMicrophoneUID.isEmpty
    }

    private var microphoneIcon: String {
        if isDefaultMicrophone { return "laptopcomputer" }
        return devices.first { $0.id == settings.selectedMicrophoneUID }?.iconName ?? "mic.fill"
    }

    private var microphoneName: String {
        if isDefaultMicrophone { return "Système (par défaut)" }
        return devices.first { $0.id == settings.selectedMicrophoneUID }?.name ?? "Microphone externe"
    }

    private var microphoneMenu: some View {
        HStack(spacing: 6) {
            MenuChip(title: microphoneName) {
                Button {
                    settings.selectedMicrophoneUID = "default"
                } label: {
                    if isDefaultMicrophone { Label("Système (par défaut)", systemImage: "checkmark") } else { Text("Système (par défaut)") }
                }
                if !devices.isEmpty {
                    Divider()
                    ForEach(devices) { device in
                        Button {
                            settings.selectedMicrophoneUID = device.id
                        } label: {
                            if settings.selectedMicrophoneUID == device.id { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                        }
                    }
                }
            }
            .frame(maxWidth: 220)
            Button {
                devices = AudioDevices.availableInputDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Color.inkSecondary)
                    .frame(width: 26, height: 26)
                    .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.Color.seam, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Actualiser la liste des microphones")
        }
    }
}

/// Clement's recorder: click, then press the combination; or pick a preset from the menu.
struct ShortcutRecorder: View {
    @Bindable var controller: DictationController
    let isCommand: Bool

    @State private var settings = Settings.shared
    @State private var isRecording = false
    @State private var heldModifiers = ""
    @State private var monitor: Any?

    private var key: PushToTalkKey { isCommand ? settings.commandModeKey : settings.pushToTalkKey }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if isRecording { stop() } else { start() }
            } label: {
                HStack(spacing: 5) {
                    if isRecording {
                        ProgressView().controlSize(.small)
                        Text(heldModifiers.isEmpty ? "Tapez la combinaison…" : heldModifiers)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Color.accent)
                    } else {
                        Text(ShortcutLabel.display(key.shortName))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.Color.ink)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isRecording ? DS.Color.selection : DS.Color.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(isRecording ? DS.Color.accent : DS.Color.seam, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Cliquez puis appuyez sur la combinaison voulue (Échap pour annuler)")

            Menu {
                ForEach(PushToTalkKey.allCases) { preset in
                    Button {
                        apply(preset)
                    } label: {
                        if preset == key { Label(preset.displayName, systemImage: "checkmark") } else { Text(preset.displayName) }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Color.inkSecondary)
                    .frame(width: 20, height: 26)
                    .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.Color.seam, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .onDisappear { stop() }
    }

    private func start() {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown && Int(event.keyCode) == kVK_Escape {
                stop()
                return nil
            }
            if event.type == .flagsChanged {
                var symbols: [String] = []
                if event.modifierFlags.contains(.control) { symbols.append("⌃") }
                if event.modifierFlags.contains(.option) { symbols.append("⌥") }
                if event.modifierFlags.contains(.command) { symbols.append("⌘") }
                if event.modifierFlags.contains(.shift) { symbols.append("⇧") }
                heldModifiers = symbols.joined(separator: " ")
            }
            if let combo = PushToTalkKey.comboFrom(event: event) {
                apply(combo)
                stop()
                return nil
            }
            return event
        }
    }

    private func apply(_ combo: PushToTalkKey) {
        if isCommand {
            settings.commandModeKey = combo
        } else {
            settings.pushToTalkKey = combo
            // The two shortcuts must differ.
            if settings.commandModeKey == combo, let other = PushToTalkKey.allCases.first(where: { $0 != combo }) {
                settings.commandModeKey = other
            }
        }
        controller.reloadHotkey()
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        heldModifiers = ""
    }
}

/// Every gesture of the shortcuts; also on the onboarding's last page.
struct ShortcutLegend: View {
    @State private var settings = Settings.shared

    private var rows: [(keys: String, action: String)] {
        let key = ShortcutLabel.display(settings.pushToTalkKey.shortName)
        var rows: [(String, String)] = [
            ("Maintenir \(key)", "Dicter ; relâcher pour taper le texte"),
            ("Toucher \(key)", "Mains libres : enregistre jusqu'au prochain appui"),
        ]
        if settings.pushToTalkKey.isModifierOnly {
            rows.append(("\(key) + Espace", "Mains libres, depuis un maintien"))
        }
        rows.append(("Échap", "Annuler — rien n'est tapé"))
        if settings.commandModeEnabled {
            rows.append((ShortcutLabel.display(settings.commandModeKey.shortName), "Mode Commande : dites comment modifier la sélection"))
        }
        rows.append(("⌥L", "Basculer la langue de dictée"))
        if settings.lastTranscriptShortcuts {
            rows.append(("⌃⌘V", "Coller la dernière transcription"))
            rows.append(("⌃⌘C", "Copier la dernière transcription"))
        }
        return rows
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: DS.Space.roomy, verticalSpacing: DS.Space.snug) {
            ForEach(rows, id: \.keys) { row in
                GridRow {
                    KeyCap(text: row.keys)
                    Text(row.action).font(DS.Font.label).foregroundStyle(DS.Color.ink)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Transcription

struct TranscriptionSettingsSection: View {
    @State private var settings = Settings.shared
    @State private var boostStatus: BoostStatus = ParakeetModels.isVocabularyModelDownloaded ? .ready : .idle
    @Environment(\.openWindow) private var openWindow

    private enum BoostStatus: Equatable {
        case idle, downloading, ready
        case failed(String)
    }

    private static let quickLanguages: [DictationLanguage] = [.french, .english, .auto]

    var body: some View {
        SectionCard {
            SettingsRow(systemImage: "globe", title: "Langue de dictée") {
                HStack(spacing: DS.Space.snug) {
                    PillTabs(
                        options: Self.quickLanguages,
                        title: { $0 == .auto ? "Auto" : $0.displayName },
                        selection: Self.quickLanguages.contains(settings.dictationLanguage) ? settings.dictationLanguage : nil,
                        small: true
                    ) { setLanguage($0) }
                    let isOther = !Self.quickLanguages.contains(settings.dictationLanguage)
                    MenuChip(title: isOther ? settings.dictationLanguage.displayName : "Autre…") {
                        ForEach(DictationLanguage.spoken.filter { !Self.quickLanguages.contains($0) }, id: \.self) { language in
                            Button(language.displayName) { setLanguage(language) }
                        }
                    }
                }
            }
            RowNote(text: languageNote)
            RowDivider()
            SettingsRow(systemImage: "waveform", title: "Moteur vocal", subtitle: settings.engine.explanation) {
                PillTabs(options: SpeechEngineChoice.allCases, title: \.shortName, selection: settings.engine, small: true) {
                    settings.engine = $0
                }
            }
            if settings.engine == .whisper {
                RowDivider()
                SettingsRow(
                    systemImage: "cpu",
                    title: "Modèle Whisper",
                    subtitle: WhisperModels.isDownloaded(variant: settings.whisperModel) ? "Installé sur ce Mac" : "Téléchargé à la première dictée"
                ) {
                    MenuChip(title: WhisperModels.availableVariants.first { $0.id == settings.whisperModel }?.displayName ?? settings.whisperModel) {
                        ForEach(WhisperModels.availableVariants) { variant in
                            Button(variant.displayName) { settings.whisperModel = variant.id }
                        }
                    }
                }
                RowDivider()
                SettingsRow(
                    systemImage: "bolt",
                    title: "Nettoyage par le modèle avec Whisper",
                    subtitle: "Whisper ponctue déjà. Le modèle local ajoute environ 3,5 s ; sans lui, les niveaux Moyen et Élevé nettoient avec les règles."
                ) {
                    RowToggle(isOn: $settings.smartCleanupOnWhisper, isEnabled: FoundationModelFormatter.isAvailable)
                }
            }
        }

        SectionCard {
            SettingsRow(systemImage: "text.magnifyingglass", title: "Renforcer les mots du dictionnaire dans Parakeet", subtitle: boostNote) {
                RowToggle(isOn: Binding(get: { settings.parakeetVocabularyBoost }, set: { setBoost($0) }))
            }
        }

        SectionCard {
            SettingsRow(
                systemImage: "square.split.2x1",
                title: "Mode comparaison",
                subtitle: "Chaque dictée passe par tous les moteurs, côte à côte. Rien n'est tapé dans ce mode."
            ) {
                HStack(spacing: DS.Space.snug) {
                    CapButton(title: "Ouvrir", height: 24) {
                        openWindow(id: "comparison")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    RowToggle(isOn: $settings.compareMode)
                }
            }
        }
    }

    private func setLanguage(_ language: DictationLanguage) {
        settings.dictationLanguage = language
        settings.prewarmCurrentEngine()
    }

    private var languageNote: String {
        switch settings.dictationLanguage {
        case .auto:
            "Apple écoute dans la langue de votre Mac ; Whisper et Parakeet détectent la langue eux-mêmes. Le nettoyage reconnaît la langue de chaque dictée."
        case .english, .french:
            "Les moteurs et le nettoyage attendent : \(settings.dictationLanguage.displayName)."
        default:
            "Les moteurs attendent : \(settings.dictationLanguage.displayName). Le nettoyage corrige les espaces et les majuscules ; les hésitations et la ponctuation dictée ne sont connues qu'en anglais et en français."
        }
    }

    private var boostNote: String {
        let what = "Un petit modèle repère les mots de votre dictionnaire dans ce que Parakeet entend. Environ 100 Mo, une fois ; réglé pour l'anglais."
        switch boostStatus {
        case .idle: return what
        case .downloading: return "Téléchargement du modèle (environ 100 Mo)…"
        case .ready: return what + " Installé."
        case .failed(let message): return "Échec du téléchargement : \(message). Désactivez puis réactivez pour réessayer."
        }
    }

    private func setBoost(_ enabled: Bool) {
        settings.parakeetVocabularyBoost = enabled
        guard enabled, boostStatus != .downloading else { return }
        boostStatus = .downloading
        Task {
            do {
                _ = try await ParakeetModels.shared.loadVocabularyModel()
                boostStatus = .ready
            } catch {
                boostStatus = .failed(error.localizedDescription)
            }
        }
    }
}

extension SpeechEngineChoice {
    var explanation: String {
        switch self {
        case .apple: "Apple : le texte s'affiche pendant que vous parlez. Rien à télécharger."
        case .whisper: "Whisper : très précis, ponctue tout seul ; le texte arrive au relâchement."
        case .parakeet: "Parakeet : le plus rapide sur la puce Apple ; le texte arrive au relâchement."
        }
    }
}

// MARK: - À propos

struct AboutSettingsSection: View {
    @Environment(\.openWindow) private var openWindow

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        SectionCard {
            HStack(spacing: DS.Space.roomy) {
                AquaOrbView(size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Fluence").font(DS.Font.title).foregroundStyle(DS.Color.ink)
                        AIBadge()
                    }
                    Text("Version \(version)").font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
                    Text("Dictée et notes de réunion, entièrement sur ce Mac.").font(DS.Font.body).foregroundStyle(DS.Color.inkSecondary)
                }
                Spacer()
            }
            .padding(DS.Space.wide)
        }

        SectionCard {
            SettingsRow(systemImage: "checklist", title: "Assistant de configuration", subtitle: "Les autorisations, une par une, en mots simples.") {
                CapButton(title: "Ouvrir…", height: 24) { OnboardingWindow.shared.show() }
            }
            RowDivider()
            SettingsRow(systemImage: "doc.text", title: "Fichier du dictionnaire", subtitle: "Un mot par ligne, modifiable dans n'importe quel éditeur.") {
                CapButton(title: "Afficher dans le Finder", height: 24) {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
            RowDivider()
            SettingsRow(systemImage: "square.split.2x1", title: "Comparaison des moteurs") {
                CapButton(title: "Ouvrir…", height: 24) {
                    openWindow(id: "comparison")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }

        RowNote(text: "Fluence est né d'une copie de murmur-youtube (per-simmons). Les modèles de transcription — Apple, Whisper (WhisperKit) et Parakeet (FluidAudio) — tournent sur ce Mac.")
            .padding(.leading, -46)
    }
}
