import AppKit
import FluenceCore
import FluenceDictionary
import SwiftUI

/// Where the main window is: which sidebar item is selected (FLU-12, navigation B).
///
/// Shared, so the menu bar, the Settings window ("Gérer les snippets") and the Window menu
/// can open the main window on a given section.
@MainActor
@Observable
final class MainNavigation {
    static let shared = MainNavigation()

    enum Section: Hashable {
        case transcriptions, dictionary, snippets, styles, meetings, upcoming
    }

    var section: Section

    private init() {
        section = DevPreview.section ?? .transcriptions
    }

    /// Selects `section` and brings the main window forward, opening it if it was closed.
    func show(_ section: Section, openWindow: OpenWindowAction) {
        self.section = section
        if section != .meetings { MeetingLibraryModel.shared.closePage() }
        // From the menu bar the app may be in the background (FLU-59): the Dock icon first.
        AppPresence.shared.becomeRegular()
        if let window = NSApp.windows.first(where: { $0.title == AppDelegate.mainTitle }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The main window: a Things-3-like sidebar and a content area (FLU-12, mock-ups 02 and 11).
struct MainWindow: View {
    @Bindable var controller: DictationController
    @State private var navigation = MainNavigation.shared
    /// FLU-37: granted, missing, or wedged (switch on, not applied).
    @State private var accessibilityState = Permissions.accessibilityState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(controller: controller, navigation: navigation)

            VStack(spacing: 0) {
                VStack(spacing: DS.Space.snug) {
                    LiveMeetingBanner(controller: .shared, navigation: navigation)
                    switch accessibilityState {
                    case .wedged: WedgedAccessibilityBanner()
                    case .missing: AccessibilityBanner()
                    case .granted: EmptyView()
                    }
                    LearnedWordsStrip()
                }
                .padding(.horizontal, DS.Space.panel)
                .padding(.top, bannerTopPadding)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Color.panel)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: DS.Window.mainMinimum.width, minHeight: DS.Window.mainMinimum.height)
        .task {
            DevPreview.openMeetingIfRequested(.shared)
            DevPreview.openImportIfRequested(.shared)
            // Dev only: the settings window on a given section, for screenshots.
            if DevPreview.settingsSection != nil { openSettings() }
            while !Task.isCancelled {
                accessibilityState = Permissions.accessibilityState
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Banners sit under the title bar; without one the content title does.
    private var bannerTopPadding: CGFloat {
        MeetingController.shared.isBusy || accessibilityState != .granted || !LearnedWords.shared.proposals.isEmpty
            ? DS.Space.wide : 0
    }

    @ViewBuilder
    private var content: some View {
        switch navigation.section {
        case .transcriptions: TranscriptionsView(controller: controller)
        case .dictionary: DictionaryPanel()
        case .snippets: SnippetPanel()
        case .styles: StylesView()
        case .meetings: MeetingsLibraryView(model: .shared)
        case .upcoming: UpcomingMeetingsView()
        }
    }
}

// MARK: - Sidebar

private struct AppSidebar: View {
    @Bindable var controller: DictationController
    @Bindable var navigation: MainNavigation
    @State private var settings = Settings.shared
    @State private var runs = RunStore.shared
    @State private var dictionary = DictionaryStore.shared
    @State private var snippets = SnippetStore.shared
    @State private var meetings = MeetingStore.shared
    @State private var upcoming = UpcomingMeetings.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: DS.Window.titleBarClearance)
            BrandBlock(subtitle: brandSubtitle, isActive: controller.state.isActive)
                .padding(.horizontal, DS.Space.base)
                .padding(.bottom, DS.Space.panel)

            group("Dictée")
            item(.transcriptions, "waveform", "Transcriptions", count: runs.runs.count)
            item(.dictionary, "book.closed", "Dictionnaire", count: dictionary.entries.count)
            item(.snippets, "text.badge.plus", "Snippets", count: snippets.entries.count)
            item(.styles, "textformat", "Styles")

            group("Réunions").padding(.top, DS.Space.wide)
            item(
                .meetings, "person.2", "Toutes les réunions",
                count: meetings.summaries.count,
                isLive: MeetingController.shared.isRecording
            )
            item(.upcoming, "calendar", "À venir", count: upcoming.isAvailable ? upcoming.events.count : nil)

            Spacer()

            SidebarItem(systemImage: "gearshape", title: "Réglages") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
            .padding(.bottom, DS.Space.snug)

            StatusChip(
                text: statusText,
                dot: controller.hotkeyStatus == .active ? DS.Color.meterGreen : DS.Color.meterAmber
            )
            .padding(.leading, DS.Space.tight)
            .help(ShortcutLabel.statusHelp(shortName: settings.pushToTalkKey.shortName, hotkey: controller.hotkeyStatus))
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.bottom, DS.Space.roomy)
        .frame(width: DS.Window.sidebar)
        .frame(maxHeight: .infinity)
        .background(DS.Color.chassis)
        .overlay(alignment: .trailing) { Rectangle().fill(DS.Color.seam).frame(width: 1) }
        .task { upcoming.refresh() }
    }

    private var brandSubtitle: String {
        "\(settings.dictationLanguage.displayName) • \(MicrophoneName.current(settings.selectedMicrophoneUID))"
    }

    /// « ⌥ Espace · Parakeet » (Clement, FLU-37): the configured shortcut and the engine.
    private var statusText: String {
        ShortcutLabel.status(
            shortName: settings.pushToTalkKey.shortName,
            engine: settings.activeEngine.shortName,
            hotkey: controller.hotkeyStatus
        )
    }

    private func group(_ title: String) -> some View {
        Silkscreen(text: title)
            .padding(.leading, 10)
            .padding(.bottom, 6)
    }

    private func item(
        _ section: MainNavigation.Section,
        _ icon: String,
        _ title: String,
        count: Int? = nil,
        isLive: Bool = false
    ) -> some View {
        SidebarItem(
            systemImage: icon,
            title: title,
            count: count,
            isSelected: navigation.section == section,
            isLive: isLive
        ) {
            navigation.section = section
            if section == .meetings { MeetingLibraryModel.shared.closePage() }
        }
    }
}

extension SpeechEngineChoice {
    /// The engine's name alone, for the status chip: "Apple", "Whisper", "Parakeet".
    var shortName: String {
        switch self {
        case .apple: "Apple"
        case .whisper: "Whisper"
        case .parakeet: "Parakeet"
        }
    }
}

/// The selected microphone's name for the brand line: "Micro système" or the device.
enum MicrophoneName {
    @MainActor
    static func current(_ uid: String) -> String {
        if uid == "default" || uid.isEmpty { return "Micro système" }
        if let device = AudioDevices.availableInputDevices().first(where: { $0.id == uid }) {
            return device.name
        }
        return "Micro externe"
    }
}

// MARK: - Attention banners

/// Amber: something needs attention (never red, which means a meeting recording). One shape
/// for every such state — Accessibility missing or wedged, the chosen microphone unplugged
/// (FLU-37, mock-up 03) — with its action(s) on the right.
private struct AttentionBanner<Actions: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    var info: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(DS.Color.meterAmber)
                .font(.system(size: 14))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                    if let info { InfoButton(text: info) }
                }
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Color.meterAmber.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(DS.Color.meterAmber.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

/// Accessibility never given (or removed by « Réparer »): typing falls back to the clipboard.
private struct AccessibilityBanner: View {
    var body: some View {
        AttentionBanner(
            systemImage: "exclamationmark.triangle.fill",
            title: "Autorisez l'Accessibilité pour que Fluence écrive à votre place",
            detail: "Sans elle, le texte reste dans le presse-papiers : collez-le avec \(PasteShortcut.label)."
        ) {
            CapButton(title: "Autoriser dans Réglages…", height: 26) {
                Permissions.promptForAccessibility()
                Permissions.openAccessibilitySettings()
            }
            // A wedge Fluence could not recognise (it was never seen trusted on this Mac):
            // the same repair as the wedged banner's.
            CapButton(title: "Réinitialiser", tint: DS.Color.inkSecondary, height: 26) {
                Task { await Permissions.repairAccessibility() }
            }
            .help("Réinitialise l'autorisation si macOS affiche l'interrupteur activé sans l'appliquer.")
        }
    }
}

/// FLU-37: the switch shows on in System Settings, macOS no longer applies it. One button.
private struct WedgedAccessibilityBanner: View {
    var body: some View {
        AttentionBanner(
            systemImage: "exclamationmark.triangle.fill",
            title: "L'Accessibilité est bloquée",
            detail: "macOS affiche l'interrupteur mais ne l'applique plus.",
            info: "Fluence est activé dans Réglages Système, mais macOS ne l'applique plus (souvent après une mise à jour). "
                + "Réparer ne retire que la ligne de Fluence, puis macOS vous la redemande."
        ) {
            CapButton(title: "Réparer", systemImage: "wrench.and.screwdriver", height: 26) {
                Task { await Permissions.repairAccessibility() }
            }
        }
    }
}

// MARK: - Dictation controls

/// Level, elapsed time and *Dicter*, top-right of the Transcriptions page.
struct DictationHeaderControls: View {
    @Bindable var controller: DictationController
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?

    private var isRecording: Bool { controller.state.isActive }

    private var meter: some View {
        VUMeter(level: controller.level, isActive: isRecording)
            .frame(width: 150, height: 32)
    }

    private var clock: some View {
        CounterChip(text: FrenchFormat.clock(elapsed))
    }

    private var button: some View {
        RecordPill(kind: isRecording ? .stopDictation : .start, title: isRecording ? "Arrêter" : "Dicter") {
            if isRecording {
                controller.stopButtonRecording()
            } else {
                controller.startButtonRecording()
            }
        }
    }

    var body: some View {
        // In a narrow window the meter gives way first, then the clock; the button stays
        // (FLU-18).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.snug) {
                meter
                clock
                button
            }
            HStack(spacing: DS.Space.snug) {
                clock
                button
            }
            button
        }
        .onChange(of: controller.state.isActive) { _, isActive in
            if isActive {
                startedAt = Date()
            } else {
                startedAt = nil
                elapsed = 0
            }
        }
        .task(id: startedAt) {
            guard let startedAt else { return }
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
