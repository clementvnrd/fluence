import SwiftUI

// Small pieces shared by the meetings library and the Meetings settings.

/// A small outlined key printed on a dark deck — the Copy / Delete chips of the existing
/// transcription list, as a component.
struct DeckKey: View {
    let title: String
    var systemImage: String?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.tight) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: DS.Library.glyph, weight: .semibold))
                }
                Silkscreen(text: title, color: DS.Color.inkOnDeck.opacity(DS.Library.inkDim))
            }
            .foregroundStyle(DS.Color.inkOnDeck.opacity(DS.Library.inkDim))
            .padding(.horizontal, DS.Space.snug)
            .padding(.vertical, DS.Space.tight)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip)
                    .strokeBorder(DS.Color.inkOnDeck.opacity(DS.Library.edgeFaint), lineWidth: DS.Border.hairline)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : DS.Library.inkFaint)
    }
}

/// A row of transport keys where exactly one is selected — the pattern the settings
/// window uses for the push-to-talk key and the model.
struct SelectorKeys<Value: Hashable>: View {
    let options: [Value]
    let title: (Value) -> String
    let selection: Value?
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            ForEach(options, id: \.self) { option in
                TransportKey(
                    title: title(option),
                    isEngaged: selection == option,
                    engagedColor: DS.Color.ink
                ) {
                    onSelect(option)
                }
                .background {
                    if selection == option {
                        RoundedRectangle(cornerRadius: DS.Radius.control)
                            .fill(DS.Color.selection)
                    }
                }
            }
        }
    }
}

/// Something went wrong that the user must know about. Printed on the panel with an
/// indicator lamp, like the dictionary editor's warnings — never red, which means recording.
struct ProblemBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
            Lamp(color: DS.Color.meterAmber, isLit: true, size: DS.Library.lampSmall)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - DS.Library.lampBaselineNudge }
            Text(message)
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.snug)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: DS.Library.glyph, weight: .bold))
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrushedPanel())
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.meterAmber.opacity(DS.Library.inkFaint), lineWidth: DS.Border.hairline)
        )
    }
}

/// A silkscreen caption over a value, as printed beside a control on the panel.
struct LabeledFact<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.hair) {
            Silkscreen(text: label)
            content
        }
    }
}
