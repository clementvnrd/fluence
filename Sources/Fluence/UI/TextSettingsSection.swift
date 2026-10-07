import FluenceCore
import SwiftUI

/// Settings for what happens to the words (FLU-5 text): cleanup level, language, and styles
/// per kind of app.
struct TextSettingsSection: View {
    @State private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.wide) {
            cleanupPanel
            languagePanel
            stylesPanel
        }
    }

    // MARK: Cleanup

    private var cleanupPanel: some View {
        SettingsPanel(label: "Cleanup") {
            SelectorKeys(
                options: CleanupLevel.allCases,
                title: \.title,
                selection: settings.cleanupLevel
            ) { settings.cleanupLevel = $0 }
            SettingsNote(settings.cleanupLevel.explanation)
            if settings.cleanupLevel.usesModel, let reason = FoundationModelFormatter.unavailableReason {
                SettingsNote("\(reason) Until then this level cleans up with the Light rules.")
            }
            SettingsNote("The dictionary's corrections and your snippets apply at every level.")
        }
    }

    // MARK: Language

    private static let quickLanguages: [DictationLanguage] = [.auto, .english, .french]

    private var languagePanel: some View {
        SettingsPanel(label: "Language") {
            HStack(spacing: DS.Space.snug) {
                SelectorKeys(
                    options: Self.quickLanguages,
                    title: \.displayName,
                    selection: Self.quickLanguages.contains(settings.dictationLanguage) ? settings.dictationLanguage : nil
                ) { settings.dictationLanguage = $0 }
                otherLanguages
            }
            SettingsNote(languageNote)
        }
    }

    /// The other 23 languages behind one key, so the row stays a row.
    private var otherLanguages: some View {
        let isOther = !Self.quickLanguages.contains(settings.dictationLanguage)
        return Menu {
            ForEach(DictationLanguage.spoken.filter { !Self.quickLanguages.contains($0) }, id: \.self) { language in
                Button(language.displayName) { settings.dictationLanguage = language }
            }
        } label: {
            Silkscreen(text: isOther ? settings.dictationLanguage.displayName : "Other…", color: DS.Color.ink)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Space.base)
        .frame(height: DS.Material.keyHeight)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(isOther ? DS.Color.selection : DS.Color.cap)
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(DS.Color.selectionEdge, lineWidth: DS.Border.hairline)
        )
        .fixedSize()
    }

    private var languageNote: String {
        switch settings.dictationLanguage {
        case .auto:
            "Apple's engine listens in your Mac's language; Parakeet detects the language itself. "
                + "Cleanup recognises the language of each dictation."
        case .english, .french:
            "Both engines and the cleanup expect \(settings.dictationLanguage.displayName)."
        default:
            "Both engines expect \(settings.dictationLanguage.displayName). Cleanup fixes spacing and "
                + "capitals; fillers and spoken punctuation are only known in English and French."
        }
    }

    // MARK: Styles

    private var stylesPanel: some View {
        SettingsPanel(label: "Styles") {
            ForEach(AppCategory.allCases, id: \.self) { category in
                HStack(spacing: DS.Space.base) {
                    Silkscreen(text: category.displayName)
                        .frame(width: DS.Parity.categoryColumn, alignment: .leading)
                    SelectorKeys(
                        options: WritingStyle.allCases,
                        title: \.displayName,
                        selection: settings.style(for: category)
                    ) { settings.styles[category] = $0 }
                }
            }
            SettingsNote(settings.cleanupLevel == .high
                ? "Chosen from the app you dictate into — Messages, Slack, Mail… — and, in a browser, "
                    + "from the page (Gmail, Slack, WhatsApp Web). The page address is read once and never kept."
                : "Styles apply at cleanup level High only.")
        }
    }
}

extension CleanupLevel {
    var title: String {
        switch self {
        case .none: "None"
        case .light: "Light"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var explanation: String {
        switch self {
        case .none: "What the engine heard, as heard."
        case .light: "Removes fillers, turns spoken punctuation into marks, fixes spacing and capitals. Instant."
        case .medium: "Light, then the on-device model: applies your self-corrections (\"5 pm, no, 6 pm\"), "
            + "formats lists, writes numbers as digits."
        case .high: "Medium, then rewritten in the style you chose for the kind of app you're typing into."
        }
    }
}
