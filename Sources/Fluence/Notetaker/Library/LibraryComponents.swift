import SwiftUI

// Shared by the main window's pages: the amber problem banner.

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
                        .keyboardFocusRing(Circle(), outset: 3)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
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
