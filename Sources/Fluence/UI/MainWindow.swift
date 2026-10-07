import MurmurDictionary
import SwiftUI

/// Main window:
/// Understated, elegant native macOS interface (Things 3 / Apple Notes style).
/// Optimized for native Dark and Light modes, with fluid navigation and clean cards.
struct MainWindow: View {
    @Bindable var controller: DictationController
    @State private var section: Section = .transcriptions
    @State private var hasAccessibility = Permissions.hasAccessibility

    enum Section: String, CaseIterable, Identifiable {
        case transcriptions
        case dictionary
        case snippets

        var id: String { rawValue }
        var title: String {
            switch self {
            case .transcriptions: "Transcriptions"
            case .dictionary: "Dictionnaire"
            case .snippets: "Snippets"
            }
        }
        var icon: String {
            switch self {
            case .transcriptions: "waveform"
            case .dictionary: "book.closed"
            case .snippets: "text.badge.plus"
            }
        }
    }

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            VStack(spacing: DS.Space.base) {
                // Top Native Toolbar
                ModernTopBar(controller: controller)

                // Accessibility Permission Alert Banner
                if !hasAccessibility {
                    accessibilityBanner
                }

                // Native Segmented Tab Control
                nativeTabBar

                // Words learned from corrections, awaiting a yes or no (opt-in, FLU-5).
                LearnedWordsStrip()

                // Content Panel
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                        .fill(DS.Color.panel)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                        )

                    Group {
                        switch section {
                        case .transcriptions: TranscriptionList()
                        case .dictionary: DictionaryPanel()
                        case .snippets: SnippetPanel()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                }
                .frame(maxHeight: .infinity)
            }
            .padding(DS.Space.roomy)
        }
        .frame(minWidth: DS.Window.mainMinimum.width, minHeight: DS.Window.mainMinimum.height)
        .task {
            while !Task.isCancelled {
                hasAccessibility = Permissions.hasAccessibility
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Color.meterAmber)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text("Permission Accessibilité requise pour le collage automatique")
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Text("macOS bloque l'injection directe de texte (⌘V) tant que l'accès n'est pas activé dans Réglages Système.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            Spacer()

            Button("Autoriser dans Réglages…") {
                Permissions.promptForAccessibility()
                Permissions.openAccessibilitySettings()
            }
            .font(DS.Font.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(DS.Color.accent)
            .background(DS.Color.cap, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(DS.Color.seam, lineWidth: 1)
            )
            .buttonStyle(.plain)

            Button("Réinitialiser TCC") {
                Permissions.resetAccessibilityTCC()
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(DS.Color.inkSecondary)
            .background(DS.Color.cap, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(DS.Color.seam, lineWidth: 1)
            )
            .buttonStyle(.plain)
            .help("Réinitialise l'autorisation si macOS affiche l'interrupteur activé sans l'appliquer.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(DS.Color.meterAmber.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                        .strokeBorder(DS.Color.meterAmber.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var nativeTabBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(Section.allCases) { item in
                    Button {
                        withAnimation(DS.Motion.panel) { section = item }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.icon)
                                .font(.system(size: 11, weight: .medium))
                            Text(item.title)
                                .font(DS.Font.label)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundStyle(section == item ? DS.Color.ink : DS.Color.inkSecondary)
                        .background {
                            if section == item {
                                Capsule()
                                    .fill(DS.Color.panel)
                                    .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(DS.Color.well, in: Capsule())

            Spacer()

            // Status Indicator Pill
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.isHotkeyActive ? DS.Color.meterGreen : DS.Color.meterAmber)
                    .frame(width: 6, height: 6)
                Text(controller.isHotkeyActive ? "Raccourci : \(Settings.shared.pushToTalkKey.shortName)" : "Raccourci inactif")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(DS.Color.well, in: Capsule())
        }
    }
}

// MARK: - Modern Top Bar

private struct ModernTopBar: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var controller: DictationController
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?

    private var isRecording: Bool { controller.state.isActive }

    var body: some View {
        HStack(spacing: DS.Space.roomy) {
            // App Identity with Aqua Voice Orb
            HStack(spacing: 10) {
                AquaOrbView(size: 28, isActive: isRecording, isListening: isRecording)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("Fluence")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(DS.Color.ink)
                        Text("AI")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                LinearGradient(
                                    colors: [Color(hex: 0x38BDF8), Color(hex: 0x0084FF)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: Capsule()
                            )
                    }
                    Text("\(Settings.shared.dictationLanguage.displayName) • \(microphoneName)")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
            }

            Spacer()

            // Centered Subtle Level Meter
            VUMeter(level: controller.level, isActive: isRecording)
                .frame(width: 180, height: 32)

            Spacer()

            // Clean Timer
            Text(counterText)
                .font(DS.Font.counter)
                .foregroundStyle(DS.Color.inkSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DS.Color.well, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))

            // Action Button (Aqua Voice Styled Pill)
            Button {
                if isRecording {
                    controller.stopButtonRecording()
                } else {
                    controller.startButtonRecording()
                }
            } label: {
                HStack(spacing: 7) {
                    if isRecording {
                        Circle()
                            .fill(Color(hex: 0xEF4444))
                            .frame(width: 8, height: 8)
                        Text("Arrêter")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xEF4444))
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white)
                        Text("Dicter")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background {
                    if isRecording {
                        Capsule()
                            .fill(Color(hex: 0xEF4444).opacity(0.12))
                            .overlay(Capsule().strokeBorder(Color(hex: 0xEF4444).opacity(0.4), lineWidth: 1))
                    } else {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: 0x38BDF8), Color(hex: 0x0084FF)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: Color(hex: 0x0084FF).opacity(0.35), radius: 6, x: 0, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)

            // Settings Button
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Color.inkSecondary)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(DS.Color.cap)
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                    .strokeBorder(DS.Color.seam, lineWidth: 1)
                            )
                    }
            }
            .buttonStyle(.plain)
            .help("Ouvrir les Réglages (⌘,)")
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.snug)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(DS.Color.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                        .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                )
                .shadow(color: DS.Shadow.raised.color, radius: DS.Shadow.raised.radius, y: DS.Shadow.raised.y)
        )
        .onChange(of: controller.state.isActive) { _, active in
            startedAt = active ? Date() : nil
            if !active { elapsed = 0 }
        }
        .task(id: startedAt) {
            guard let startedAt else { return }
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var counterText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var microphoneName: String {
        let uid = Settings.shared.selectedMicrophoneUID
        if uid == "default" || uid.isEmpty {
            return "Micro système"
        }
        if let dev = AudioDevices.availableInputDevices().first(where: { $0.id == uid }) {
            return dev.name
        }
        return "Micro externe"
    }
}

// MARK: - Modern Transcriptions List

private struct TranscriptionList: View {
    @State private var store = RunStore.shared
    @State private var query = ""
    @State private var isConfirmingClear = false

    private var runs: [DictationRun] {
        let all = store.runs.reversed().map { $0 }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.text.localizedStandardContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $query, placeholder: "Rechercher parmi les transcriptions…")

            // History couldn't be read or saved (the Keychain refused the key). Persistent
            // rather than a toast, because the failure persists.
            if let problem = store.problem {
                ProblemStrip(message: problem)
            }

            if runs.isEmpty {
                EmptyPanel(
                    label: store.runs.isEmpty ? "Aucune dictée enregistrée" : "Aucun résultat",
                    detail: store.runs.isEmpty ? "Maintenez votre raccourci pour commencer." : "Essayez une autre recherche."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(runs) { run in
                            ModernTranscriptionCard(run: run) {
                                withAnimation(DS.Motion.panel) { RunLog.delete(run) }
                            }
                        }
                    }
                    .padding(DS.Space.base)
                }
                modernFooter
            }
        }
    }

    private var modernFooter: some View {
        HStack {
            Text("\(store.runs.count) enregistrement\(store.runs.count == 1 ? "" : "s")")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            Spacer()
            Button { isConfirmingClear = true } label: {
                Text("Tout effacer")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, 8)
        .background(DS.Color.well)
        .overlay(alignment: .top) {
            Rectangle().fill(DS.Color.seam).frame(height: 1)
        }
        .confirmationDialog(
            "Supprimer l'ensemble des \(store.runs.count) enregistrements ?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Tout supprimer", role: .destructive) { RunLog.clear() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action est irréversible.")
        }
    }
}

// MARK: - Modern Transcription Card

private struct ModernTranscriptionCard: View {
    let run: DictationRun
    let onDelete: () -> Void

    @State private var didCopy = false
    @State private var isHovering = false
    @State private var isShowingCorrection = false
    /// What the engine heard before cleanup, when cleanup changed it (main's FLU-5 "Raw").
    @State private var showsRaw = false

    private var shownText: String { showsRaw ? run.rawText ?? run.text : run.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row with metadata badges
            HStack(spacing: 8) {
                // Engine Badge
                Text(run.engine)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Color.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DS.Color.selection, in: Capsule())

                // Latency Badge
                Text(String(format: "%.2fs", run.processSeconds))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.Color.inkSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DS.Color.well, in: Capsule())

                Spacer()

                // Timestamp
                Text(run.date, style: .time)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)

                // Learn & Correct Button
                Button {
                    isShowingCorrection = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                            .font(.system(size: 10))
                        Text("Corriger")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(DS.Color.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DS.Color.selection, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(DS.Color.selectionEdge, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help("Corriger cette dictée pour que Fluence apprenne automatiquement")
                .sheet(isPresented: $isShowingCorrection) {
                    CorrectionQuickSheet(initialText: run.text)
                }

                // Raw / cleaned switch, when cleanup changed something.
                if run.rawText != nil {
                    Button { showsRaw.toggle() } label: {
                        Text(showsRaw ? "Nettoyé" : "Brut")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(showsRaw ? DS.Color.accent : DS.Color.inkSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(showsRaw ? DS.Color.selection : DS.Color.cap, in: Capsule())
                            .overlay(Capsule().strokeBorder(DS.Color.seam, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(showsRaw ? "Afficher le texte nettoyé" : "Afficher ce qui a été entendu, avant le nettoyage")
                }

                // Copy Button
                Button {
                    // Asked for, so an ordinary copy — but this Mac only: Universal Clipboard
                    // would hand the dictation to every device on the account.
                    let pasteboard = NSPasteboard.general
                    pasteboard.prepareForNewContents(with: .currentHostOnly)
                    pasteboard.setString(shownText, forType: .string)
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        didCopy = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(didCopy ? "Copié !" : "Copier")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(didCopy ? DS.Color.meterGreen : DS.Color.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(didCopy ? DS.Color.meterGreen.opacity(0.12) : DS.Color.cap, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(DS.Color.seam, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)

                // Delete Button
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Color.inkSecondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 0.8 : 0.25)
                .help("Supprimer cet enregistrement")
            }

            // Transcript Body Text
            Text(shownText)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(2)

            // Applied Corrections
            if let corrections = run.corrections, !corrections.isEmpty {
                ModernCorrectionPills(corrections: corrections)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHovering ? DS.Color.hover : DS.Color.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                )
                .shadow(
                    color: isHovering ? DS.Shadow.panel.color : DS.Shadow.raised.color,
                    radius: isHovering ? DS.Shadow.panel.radius : DS.Shadow.raised.radius,
                    x: 0,
                    y: isHovering ? DS.Shadow.panel.y : DS.Shadow.raised.y
                )
        )
        .onHover { isHovering = $0 }
    }
}

private struct ModernCorrectionPills: View {
    let corrections: [AppliedCorrection]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 9))
                .foregroundStyle(DS.Color.meterAmber)

            ForEach(corrections, id: \.self) { correction in
                HStack(spacing: 4) {
                    Text(correction.from)
                        .strikethrough()
                        .foregroundStyle(DS.Color.inkSecondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7))
                        .foregroundStyle(DS.Color.inkSecondary)
                    Text(correction.to)
                        .foregroundStyle(DS.Color.ink)
                    if correction.count > 1 {
                        Text("×\(correction.count)")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.Color.inkSecondary)
                    }
                }
                .font(.system(size: 10))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(DS.Color.meterAmber.opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Spacer()
        }
    }
}

// MARK: - History fault

/// A fault line under the search field: history couldn't be read or saved.
private struct ProblemStrip: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DS.Color.meterAmber)
            Text(message)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.meterAmber.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Color.seam).frame(height: 1)
        }
    }
}

// MARK: - Modern Search Field

struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Color.inkSecondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, 8)
        .background(DS.Color.well)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Color.seam).frame(height: 1)
        }
    }
}

// MARK: - Modern Empty State

struct EmptyPanel: View {
    let label: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "mic.slash")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(DS.Color.inkSecondary.opacity(0.5))
                .padding(.bottom, 2)

            Text(label)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)

            Text(detail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
