import AppKit
import FluenceCore
import MurmurDictionary
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

    var section: Section = .transcriptions

    private init() {}

    /// Selects `section` and brings the main window forward, opening it if it was closed.
    func show(_ section: Section, openWindow: OpenWindowAction) {
        self.section = section
        if section != .meetings { MeetingLibraryModel.shared.closePage() }
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
    @State private var hasAccessibility = Permissions.hasAccessibility

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(controller: controller, navigation: navigation)

            VStack(spacing: 0) {
                VStack(spacing: DS.Space.snug) {
                    LiveMeetingBanner(controller: .shared, navigation: navigation)
                    if !hasAccessibility { AccessibilityBanner() }
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
            while !Task.isCancelled {
                hasAccessibility = Permissions.hasAccessibility
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Banners sit under the title bar; without one the content title does.
    private var bannerTopPadding: CGFloat {
        MeetingController.shared.isBusy || !hasAccessibility || !LearnedWords.shared.proposals.isEmpty
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
                dot: controller.isHotkeyActive ? DS.Color.meterGreen : DS.Color.meterAmber
            )
            .padding(.leading, DS.Space.tight)
            .help(controller.isHotkeyActive
                ? "Maintenez \(ShortcutLabel.display(settings.pushToTalkKey.shortName)) pour dicter"
                : "Le raccourci n'est pas actif : vérifiez l'autorisation Accessibilité dans les Réglages.")
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

    /// "Raccourci ⌥ · Whisper · Français".
    private var statusText: String {
        guard controller.isHotkeyActive else { return "Raccourci inactif" }
        return "Raccourci \(ShortcutLabel.modifiers(settings.pushToTalkKey.shortName)) · "
            + "\(settings.engine.shortName) · \(settings.dictationLanguage.displayName)"
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

// MARK: - Accessibility banner

/// Amber: something needs attention (never red, which means a meeting recording).
private struct AccessibilityBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Color.meterAmber)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("Autorisez l'Accessibilité pour que Fluence écrive à votre place")
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Text("Sans elle, le texte reste dans le presse-papiers : collez-le avec ⌘V.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            Spacer()
            CapButton(title: "Autoriser dans Réglages…", height: 26) {
                Permissions.promptForAccessibility()
                Permissions.openAccessibilitySettings()
            }
            CapButton(title: "Réinitialiser", tint: DS.Color.inkSecondary, height: 26) {
                Permissions.resetAccessibilityTCC()
            }
            .help("Réinitialise l'autorisation si macOS affiche l'interrupteur activé sans l'appliquer.")
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

// MARK: - Dictation controls

/// Level, elapsed time and *Dicter*, top-right of the Transcriptions page.
struct DictationHeaderControls: View {
    @Bindable var controller: DictationController
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?

    private var isRecording: Bool { controller.state.isActive }

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            VUMeter(level: controller.level, isActive: isRecording)
                .frame(width: 150, height: 32)
            CounterChip(text: FrenchFormat.clock(elapsed))
            RecordPill(kind: isRecording ? .stopDictation : .start, title: isRecording ? "Arrêter" : "Dicter") {
                if isRecording {
                    controller.stopButtonRecording()
                } else {
                    controller.startButtonRecording()
                }
            }
        }
        .onChange(of: controller.state.isActive) { _, active in
            startedAt = active ? Date() : nil
            if !active { elapsed = 0 }
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
