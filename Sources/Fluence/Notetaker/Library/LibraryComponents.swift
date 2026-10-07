import SwiftUI

// Small pieces shared by the meetings library and the Meetings settings.

/// A small pill key — the Copier / Supprimer chips of the transcription list, as a
/// component.
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
                        .font(.system(size: DS.Library.glyphLarge, weight: .medium))
                }
                Text(title)
                    .font(DS.Font.label)
            }
            .foregroundStyle(DS.Color.ink)
            .padding(.horizontal, DS.Space.snug)
            .padding(.vertical, DS.Space.tight)
            .background(DS.Color.cap, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            )
            .contentShape(Capsule())
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
                // Engaged: the accent on the selection tint, drawn by the key itself.
                TransportKey(
                    title: title(option),
                    isEngaged: selection == option
                ) {
                    onSelect(option)
                }
            }
        }
    }
}

/// Something went wrong that the user must know about. An amber card with a warning
/// sign, like the main window's Accessibility banner — never red, which means recording.
struct ProblemBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DS.Library.glyphLarge + 2))
                .foregroundStyle(DS.Color.meterAmber)
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
                .help("Masquer")
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(DS.Color.meterAmber.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                        .strokeBorder(DS.Color.meterAmber.opacity(DS.Library.edgeFaint), lineWidth: DS.Border.seam)
                )
        )
    }
}

/// A small label over a value, as beside a control on a card.
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
