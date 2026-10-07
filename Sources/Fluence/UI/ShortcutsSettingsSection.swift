import SwiftUI

/// Settings ▸ Shortcuts (FLU-5): every gesture of the push-to-talk key in one card, the
/// Command Mode modifier, and the switch for the last-transcript chords.
///
/// The card is printed like the legend under a deck's transport keys: what to press on the
/// left, what it does on the right. It follows the chosen push-to-talk key, so it never
/// describes a key the user isn't using.
struct ShortcutsSettingsSection: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared

    private var key: String { settings.pushToTalkKey.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Silkscreen(text: "Shortcuts", large: true)

            ShortcutLegend()

            Silkscreen(text: "Command Mode key")
            HStack(spacing: DS.Space.snug) {
                ForEach(CommandModifier.allCases, id: \.self) { modifier in
                    TransportKey(
                        title: modifier.displayName,
                        isEngaged: settings.commandModifier == modifier,
                        engagedColor: DS.Color.ink
                    ) {
                        settings.commandModifier = modifier
                        controller.reloadHotkey()
                    }
                    .background {
                        if settings.commandModifier == modifier {
                            RoundedRectangle(cornerRadius: DS.Radius.control)
                                .fill(DS.Color.selection)
                        }
                    }
                }
            }
            note(commandNote)

            Toggle(isOn: Binding(
                get: { settings.lastTranscriptShortcuts },
                set: { on in
                    settings.lastTranscriptShortcuts = on
                    controller.reloadHotkey()
                }
            )) {
                Silkscreen(text: "⌃⌘V / ⌃⌘C for the last transcript")
            }
            .toggleStyle(.switch)
            note("The last transcript is kept in memory only, until you quit. Turn this off if "
                + "another app needs these keys.")
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrushedPanel())
    }

    private var commandNote: String {
        if let reason = FoundationModelFormatter.unavailableReason {
            return "Command Mode rewrites with Apple Intelligence, on this Mac. \(reason)"
        }
        return "Select text, hold \(key) with this key and say what to change — \"make it "
            + "shorter\", \"translate to French\". With nothing selected, the whole field is "
            + "rewritten. On this Mac, with Apple Intelligence."
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.label)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The legend itself, also shown on the onboarding window's last page.
struct ShortcutLegend: View {
    @State private var settings = Settings.shared

    private var rows: [(keys: String, action: String)] {
        let key = settings.pushToTalkKey.displayName
        var rows: [(String, String)] = [
            ("Hold \(key)", "Dictate; let go to type"),
            ("\(key) \(key)", "Hands-free: double-tap, keeps recording"),
            ("\(key) + Space", "Hands-free, from a hold"),
            ("\(key)", "Tap to end hands-free and type"),
            ("Esc", "Cancel — nothing is typed"),
        ]
        if settings.commandModifier != .off {
            rows.append(("\(key) + \(settings.commandModifier.displayName)", "Command Mode: say how to change the selection"))
        }
        if settings.lastTranscriptShortcuts {
            rows.append(("⌃⌘V", "Paste the last transcript"))
            rows.append(("⌃⌘C", "Copy the last transcript"))
        }
        return rows
    }

    var body: some View {
        DeckWindow {
            Grid(alignment: .leading, horizontalSpacing: DS.Space.roomy, verticalSpacing: DS.Space.snug) {
                ForEach(rows, id: \.keys) { row in
                    GridRow {
                        Readout(text: row.keys)
                        Text(row.action)
                            .font(DS.Font.label)
                            .foregroundStyle(DS.Color.inkOnDeck)
                    }
                }
            }
            .padding(DS.Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
