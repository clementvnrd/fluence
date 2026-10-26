import AppKit
import Carbon.HIToolbox
import FluenceCore
import SwiftUI

/// Réglages (FLU-12, mock-ups 08 and 09): a section list on the left, the section on the
/// right. Every setting of the earlier tabbed window is here — see
/// `docs/DESIGN-FLU-12.md` for the map from old tab to new section.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    @State private var selection: SettingsSection = DevPreview.settingsSection ?? .dictation

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
                    ContentTitle(title: selection.title)  // the title says it; no sentence under it (FLU-19)
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
        // The Settings scene keeps its title and toolbar hairline even with a hidden title
        // bar; the sidebar's "Réglages" is the title here (mock-up 08).
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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

/// « Lancer Fluence au démarrage du Mac » (FLU-58). The toggle shows what macOS says, read again
/// whenever Fluence comes back to the front: the switch also lives in System Settings.
private struct LaunchAtLoginCard: View {
    @State private var login = LaunchAtLogin.shared

    var body: some View {
        SectionCard {
            SettingsRow(
                systemImage: "power",
                title: "Lancer Fluence au démarrage du Mac",
                info: "Fluence démarre dans la barre des menus, sans ouvrir de fenêtre : la dictée est prête dès la connexion."
            ) {
                RowToggle(
                    isOn: Binding(get: { login.isOn }, set: { login.set($0) }),
                    isEnabled: login.isAvailable
                )
            }
            if !login.isAvailable {
                RowNote(text: "Disponible depuis Fluence installée dans Applications.")
            } else if login.needsApproval {
                RowNote(text: "macOS attend votre accord dans Réglages Système › Général › Ouverture.", color: DS.Color.amberText)
                HStack {
                    CapButton(title: "Ouvrir Réglages Système", height: 24) { login.openSystemSettings() }
                    Spacer()
                }
                .padding(.leading, 46)
                .padding(.bottom, 12)
            }
            if let problem = login.problem {
                RowNote(text: problem, color: DS.Color.faultText)
            }
        }
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }
}

struct DictationSettingsSection: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        SectionCard {
            SettingsRow(systemImage: "keyboard", title: "Raccourci de dictée", info: "Maintenez pour dicter ; touchez pour les mains libres.") {
                ShortcutRecorder(controller: controller, isCommand: false)
            }
            RowDivider()
            SettingsRow(systemImage: microphoneIcon, title: "Microphone") {
                microphoneMenu
            }
            RowDivider()
            SettingsRow(systemImage: "timer", title: "Durée maximale d'une dictée", info: "Au-delà, la dictée est terminée et tapée.") {
                PillTabs(
                    options: Settings.recordingLimitChoices,
                    title: { "\($0)\(FrenchFormat.space)min" },
                    selection: settings.maxRecordingMinutes,
                    small: true
                ) { settings.maxRecordingMinutes = $0 }
            }
            RowDivider()
            SettingsRow(systemImage: "speaker.wave.2", title: "Son", info: "Un léger signal au début et à la fin de la dictée.") {
                RowToggle(isOn: $settings.soundEnabled)
            }
        }

        LaunchAtLoginCard()

        SectionCard {
            SettingsRow(
                systemImage: "wand.and.stars",
                title: "Mode Commande",
                subtitle: FoundationModelFormatter.isAvailable ? nil : "Nécessite Apple Intelligence sur ce Mac",
                info: "Sélectionnez un texte, maintenez le raccourci et dites comment le réécrire."
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
                info: "Gardée en mémoire seulement, jusqu'à ce que vous quittiez."
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
            SettingsRow(systemImage: "hand.tap", title: "Gestes", info: "Ce que font vos raccourcis, partout sur le Mac.") { EmptyView() }
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
                    .keyboardFocusRing(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
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
            .menuStyle(.button)
            .buttonStyle(.plain)
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
    @State private var models = SpeechModelStore.shared
    /// The model whose *Supprimer…* was clicked, waiting for the confirmation.
    @State private var pendingDeletion: InstalledSpeechModel?
    @Environment(\.openWindow) private var openWindow

    private enum BoostStatus: Equatable {
        case idle, downloading, ready
        case failed(String)
    }

    private static let quickLanguages: [DictationLanguage] = [.french, .english, .auto]

    var body: some View {
        SectionCard {
            SettingsRow(systemImage: "globe", title: "Langue de dictée", info: languageNote) {
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
            if let languageCaveat {
                RowNote(text: languageCaveat, color: DS.Color.amberText)
            }
            RowDivider()
            SettingsRow(systemImage: "waveform", title: "Moteur vocal", info: settings.engine.explanation) {
                PillTabs(options: SpeechEngineChoice.allCases, title: \.shortName, selection: settings.engine, small: true) {
                    settings.engine = $0
                }
            }
            if let engineCaveat {
                RowNote(text: engineCaveat, color: DS.Color.amberText)
            }
            // FLU-29: Parakeet selected (or the French default) but not on disk yet — its
            // download, asked for here, with Apple standing in meanwhile.
            if settings.isWaitingForParakeet {
                RowDivider()
                ParakeetDownloadRow()
            }
            if settings.engine == .whisper {
                RowDivider()
                SettingsRow(
                    systemImage: "cpu",
                    title: "Modèle Whisper",
                    subtitle: WhisperModels.isDownloaded(variant: settings.whisperModel) ? nil : "Téléchargé à la première dictée"
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
                    info: "Whisper ponctue déjà. Le modèle local ajoute environ 3,5 s ; sans lui, les niveaux Moyen et Élevé nettoient avec les règles."
                ) {
                    RowToggle(isOn: $settings.smartCleanupOnWhisper, isEnabled: FoundationModelFormatter.isAvailable)
                }
            }
        }
        .task {
            await models.refresh()
            ParakeetDownload.shared.refresh()
        }
        .onChange(of: settings.engine) { models.reclassify() }
        .onChange(of: settings.whisperModel) { models.reclassify() }
        .onChange(of: settings.parakeetVocabularyBoost) { models.reclassify() }
        .onChange(of: settings.compareMode) { models.reclassify() }

        if !models.installed.isEmpty {
            modelsCard
        }

        SectionCard {
            SettingsRow(systemImage: "text.magnifyingglass", title: "Renforcer les mots du dictionnaire dans Parakeet", subtitle: boostState, info: Self.boostInfo) {
                RowToggle(isOn: Binding(get: { settings.parakeetVocabularyBoost }, set: { setBoost($0) }))
            }
        }

        SectionCard {
            SettingsRow(
                systemImage: "square.split.2x1",
                title: "Mode comparaison",
                info: "Chaque dictée passe par les moteurs déjà téléchargés, côte à côte. Rien n'est tapé dans ce mode."
            ) {
                HStack(spacing: DS.Space.snug) {
                    CapButton(title: "Ouvrir", height: 24) {
                        openWindow(id: "comparison")
                        NSApp.activate()
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

    // MARK: FLU-31 — models on this Mac

    private static let modelsInfo = "Les modèles vocaux téléchargés. Ceux qui ne servent pas peuvent être supprimés ; Fluence les retélécharge si vous les choisissez à nouveau."

    /// Every model on disk with its size; *Supprimer…* only on the ones nothing uses, and
    /// nothing leaves the disk without the confirmation below.
    private var modelsCard: some View {
        SectionCard {
            SettingsRow(
                systemImage: "internaldrive",
                title: "Modèles sur ce Mac",
                subtitle: FrenchFormat.bytes(SpeechModelInventory.totalBytes(models.installed)),
                info: Self.modelsInfo
            ) { EmptyView() }
            ForEach(models.installed) { model in
                RowDivider()
                SettingsRow(systemImage: "cpu", title: model.model.displayName, subtitle: model.subtitle) {
                    if model.canDelete {
                        DestructiveButton(title: "Supprimer…", height: 24) { pendingDeletion = model }
                    }
                }
            }
            if let failure = models.failure {
                RowNote(text: failure, color: DS.Color.amberText)
            }
        }
        .confirmationDialog(
            pendingDeletion.map { "Supprimer \($0.model.displayName) ?" } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { model in
            Button("Placer dans la Corbeille", role: .destructive) {
                Task {
                    await models.moveToTrash(model.model)
                    // FLU-29: Parakeet gone from disk means Apple again until it is fetched.
                    ParakeetDownload.shared.refresh()
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: { model in
            Text("\(FrenchFormat.bytes(model.bytes)) libérés une fois la Corbeille vidée. Fluence le retélécharge si vous le choisissez à nouveau.")
        }
    }

    private var languageNote: String {
        switch settings.dictationLanguage {
        case .auto:
            "Apple écoute dans la langue de votre Mac ; Whisper et Parakeet détectent la langue eux-mêmes. Le nettoyage reconnaît la langue de chaque dictée."
        default:
            "Les moteurs et le nettoyage attendent : \(settings.dictationLanguage.displayName)."
        }
    }

    /// Shown under the row, because it changes what the user gets: cleanup only knows the
    /// fillers and dictated punctuation of English and French.
    private var languageCaveat: String? {
        switch settings.dictationLanguage {
        case .auto, .english, .french: nil
        default: "Hors anglais et français, le nettoyage corrige seulement les espaces et les majuscules."
        }
    }

    /// FLU-24: on the French bench, Parakeet makes half Apple's errors on tech words and a
    /// quarter of Whisper Small's through a webcam mic. Said where the choice is made.
    private var engineCaveat: String? {
        guard settings.engine != .parakeet,
              settings.dictationLanguage == .french || settings.dictationLanguage == .auto
        else { return nil }
        return "Parakeet est plus précis en français."
    }

    private static let boostInfo = "Un petit modèle repère les mots de votre dictionnaire dans ce que Parakeet entend. Environ 100 Mo, une fois ; réglé pour l'anglais."

    /// The download's state, when there is one to tell (FLU-19: the explanation is in ⓘ).
    private var boostState: String? {
        switch boostStatus {
        case .idle: nil
        case .downloading: "Téléchargement du modèle (environ 100 Mo)…"
        case .ready: "Installé"
        case .failed(let message): "Échec du téléchargement : \(message). Désactivez puis réactivez pour réessayer."
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

/// FLU-29 (mock-up 04): Parakeet Ultra's download in Réglages › Transcription — a button
/// before, a bar with ✕ during, « Réessayer » after a failure. Apple takes the dictations
/// until it is done, and the subtitle says so.
private struct ParakeetDownloadRow: View {
    @State private var download = ParakeetDownload.shared

    private var failed: Bool { download.phase == .failed }

    var body: some View {
        SettingsRow(
            systemImage: failed ? "exclamationmark.triangle.fill" : "arrow.down.circle",
            title: "Parakeet Ultra",
            subtitle: subtitle,
            iconTint: failed ? DS.Color.meterAmber : DS.Color.accent
        ) {
            switch download.phase {
            case .downloading(let fraction):
                HStack(spacing: 10) {
                    DownloadBar(fraction: fraction).frame(width: 150)
                    Text(FrenchFormat.percent(fraction))
                        .font(DS.Font.counter)
                        .foregroundStyle(DS.Color.accent)
                        .frame(width: 44, alignment: .trailing)
                    Button { download.cancel() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Color.silkscreen)
                    }
                    .buttonStyle(.plain)
                    .help("Annuler le téléchargement")
                }
            case .idle:
                CapButton(title: "Télécharger", systemImage: "arrow.down", height: 26) { download.start() }
            case .failed:
                CapButton(title: "Réessayer", systemImage: "arrow.clockwise", height: 26) { download.start() }
            }
        }
    }

    private var subtitle: String {
        switch download.phase {
        case .downloading(let fraction):
            DownloadProgressText.amount(fraction: fraction, totalBytes: ParakeetDownload.totalBytes) + " · Apple en attendant"
        case .idle:
            "Environ " + FrenchFormat.bytes(ParakeetDownload.totalBytes) + " · Apple en attendant"
        case .failed:
            "Échec du téléchargement · Apple en attendant"
        }
    }
}

extension SpeechEngineChoice {
    var explanation: String {
        switch self {
        case .apple: "Apple : le texte s'affiche pendant que vous parlez. Rien à télécharger ; moins précis sur les mots techniques."
        case .whisper: "Whisper : le texte arrive au relâchement. Plus lent et moins précis que Parakeet en français."
        case .parakeet: "Parakeet Ultra : le plus précis et le plus rapide, en français comme en anglais. Le texte arrive au relâchement. Recommandé."
        }
    }
}

// MARK: - À propos

struct AboutSettingsSection: View {
    @Environment(\.openWindow) private var openWindow
    /// Mirrors Sparkle's setting, which SwiftUI cannot observe.
    @State private var checksAutomatically = AppUpdater.shared.checksAutomatically
    @State private var exportFailed = false

    /// FLU-35: the file goes where the user saves it, then shows in the Finder so it can be
    /// attached to a message.
    private func exportDiagnostic() {
        Task {
            do {
                exportFailed = false
                if let url = try await DiagnosticExport.save() {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                exportFailed = true
                Log.app.error("diagnostic export failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
                Diagnostics.error("diagnostics.export", error)
            }
        }
    }

    /// "Vérifié aujourd'hui, 09:12", or "Jamais vérifié".
    private var lastCheckText: String {
        guard let date = AppUpdater.shared.lastCheck else { return "Jamais vérifié" }
        let when = FrenchDates.relativeDayTime(date, now: .now, calendar: .current)
        return "Vérifié " + when.prefix(1).lowercased() + when.dropFirst()
    }

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

        // FLU-26: hidden in a build without an update feed.
        if AppUpdater.shared.isRunning {
            SectionCard {
                SettingsRow(systemImage: "arrow.down.circle", title: "Mises à jour", subtitle: lastCheckText) {
                    CapButton(title: "Rechercher…", height: 24) { AppUpdater.shared.checkNow() }
                }
                RowDivider()
                SettingsRow(
                    systemImage: "arrow.triangle.2.circlepath",
                    title: "Rechercher automatiquement",
                    info: "Une fois par jour, Fluence regarde sur GitHub si une nouvelle version existe et la télécharge. Elle n'est installée qu'avec votre accord, ou quand vous quittez Fluence. Rien d'autre n'est envoyé."
                ) {
                    RowToggle(isOn: Binding(
                        get: { checksAutomatically },
                        set: { on in
                            checksAutomatically = on
                            AppUpdater.shared.checksAutomatically = on
                        }
                    ))
                }
            }
        }

        SectionCard {
            SettingsRow(systemImage: "checklist", title: "Assistant de configuration", info: "Les autorisations, une par une, en mots simples.") {
                CapButton(title: "Ouvrir…", height: 24) { OnboardingWindow.shared.show() }
            }
            RowDivider()
            SettingsRow(systemImage: "doc.text", title: "Fichier du dictionnaire", info: "Un mot par ligne, modifiable dans n'importe quel éditeur.") {
                CapButton(title: "Afficher dans le Finder", height: 24) {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
            RowDivider()
            SettingsRow(systemImage: "square.split.2x1", title: "Comparaison des moteurs") {
                CapButton(title: "Ouvrir…", height: 24) {
                    openWindow(id: "comparison")
                    NSApp.activate()
                }
            }
            RowDivider()
            SettingsRow(
                systemImage: "doc.plaintext",
                title: "Licences",
                info: "Les bibliothèques libres et les modèles de transcription sur lesquels Fluence s'appuie, avec leurs licences."
            ) {
                // Absent when the binary runs outside an app bundle (`swift run`).
                let notices = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt")
                CapButton(title: "Ouvrir…", height: 24) {
                    if let notices { NSWorkspace.shared.open(notices) }
                }
                .disabled(notices == nil)
            }
            RowDivider()
            // FLU-35: a file the user saves and sends if they want to; nothing is sent.
            SettingsRow(
                systemImage: "stethoscope",
                title: "Exporter un diagnostic",
                info: "Versions, réglages, nombres et durées, dernières erreurs et dates des plantages. Aucun texte dicté, aucune réunion, aucun nom. Rien n'est envoyé : vous choisissez où l'enregistrer."
            ) {
                CapButton(title: "Exporter…", height: 24) { exportDiagnostic() }
            }
            if exportFailed {
                RowNote(text: "Le diagnostic n'a pas pu être enregistré.", color: DS.Color.faultText)
            }
        }

        RowNote(text: "Fluence est né d'une copie de murmur-youtube (per-simmons). Les modèles de transcription — Apple, Whisper (WhisperKit) et Parakeet (FluidAudio) — tournent sur ce Mac.")
            .padding(.leading, -46)
    }
}
