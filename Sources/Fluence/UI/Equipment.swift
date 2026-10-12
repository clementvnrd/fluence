import SwiftUI

// MARK: - Modern 2026 Surfaces & Cards

/// A modern elevated card panel with subtle glassmorphism borders and shadows.
struct BrushedPanel: View {
    var radius: CGFloat = DS.Radius.panel

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(DS.Color.panel)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            )
            .shadow(
                color: DS.Shadow.raised.color,
                radius: DS.Shadow.raised.radius,
                x: DS.Shadow.raised.x,
                y: DS.Shadow.raised.y
            )
    }
}

/// A clean recessed content well with subtle background tint.
struct Well<Content: View>: View {
    var radius: CGFloat = DS.Radius.panel
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(DS.Color.well, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            )
    }
}

/// Modern floating readout window.
struct DeckWindow<Content: View>: View {
    var radius: CGFloat = DS.Radius.control
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(DS.Color.deck, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            )
    }
}

// MARK: - Modern Labels

/// Clean, modern section label.
struct Silkscreen: View {
    let text: String
    var large = false
    var color: Color = DS.Color.silkscreen

    var body: some View {
        Text(text)
            .font(large ? DS.Font.silkscreenLarge : DS.Font.silkscreen)
            .foregroundStyle(color)
    }
}

// MARK: - Accents & Indicators

/// Modern glowing indicator dot.
struct Lamp: View {
    let color: Color
    var isLit: Bool
    var size: CGFloat = DS.Material.lampSize

    var body: some View {
        ZStack {
            if isLit {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: size * 1.8, height: size * 1.8)
                    .blur(radius: 2)
            }
            Circle()
                .fill(isLit ? color : DS.Color.recordIdle)
                .frame(width: size, height: size)
        }
        .animation(DS.Motion.lamp, value: isLit)
    }
}

// MARK: - Modern Interactive Buttons

/// Modern Apple-style interactive button with smooth hover and active state.
struct TransportKey: View {
    let title: String
    var systemImage: String?
    var isEngaged = false
    var engagedColor: Color = DS.Color.accent
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.snug) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(DS.Font.label)
            }
            .foregroundStyle(labelColor)
            .frame(minWidth: DS.Material.keyMinWidth)
            .frame(height: DS.Material.keyHeight)
            .padding(.horizontal, DS.Space.base)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(backgroundFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(borderStroke, lineWidth: 1)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var labelColor: Color {
        if isEngaged {
            return isEngaged && engagedColor == DS.Color.record ? Color.white : DS.Color.accent
        }
        return DS.Color.ink
    }

    private var backgroundFill: Color {
        if isEngaged {
            return engagedColor == DS.Color.record ? DS.Color.record : DS.Color.selection
        }
        return isHovered ? DS.Color.hover : DS.Color.cap
    }

    private var borderStroke: Color {
        if isEngaged {
            return engagedColor == DS.Color.record ? DS.Color.record : DS.Color.selectionEdge.opacity(0.5)
        }
        return isHovered ? DS.Color.seam : DS.Color.seam.opacity(0.6)
    }
}

// MARK: - Modern Audio Visualizer (Waveform & Level)

/// A sleek, modern audio level visualizer with dynamic pulsating bars.
struct VUMeter: View {
    let level: Float
    var isActive: Bool

    private static let barCount = 18

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(barGradient(for: index))
                    .frame(width: 3, height: barHeight(for: index))
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.well, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Color.seam, lineWidth: 1)
        )
    }

    private func barHeight(for index: Int) -> CGFloat {
        let baseHeight: CGFloat = 4
        guard isActive else { return baseHeight }

        // The level scales a fixed, centre-weighted shape (FLU-23): the bars stand still and
        // flat in silence and rise together with the voice, instead of reshuffling.
        let normalizedIndex = Double(index) / Double(Self.barCount - 1)
        let centerWeight = max(1.0 - abs(normalizedIndex - 0.5) * 1.4, 0.3)
        let texture = 0.85 + 0.15 * sin(Double(index) * 2.1)
        let dynamic = CGFloat(Double(level) * centerWeight * texture)

        return min(38, baseHeight + dynamic * 34)
    }

    private func barGradient(for index: Int) -> LinearGradient {
        guard isActive else {
            return LinearGradient(
                colors: [DS.Color.inkSecondary.opacity(0.3), DS.Color.inkSecondary.opacity(0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        let ratio = Double(index) / Double(Self.barCount)
        if ratio > 0.85 {
            return LinearGradient(
                colors: [DS.Color.meterRed, DS.Color.meterAmber],
                startPoint: .top,
                endPoint: .bottom
            )
        } else if ratio > 0.65 {
            return LinearGradient(
                colors: [DS.Color.meterAmber, DS.Color.accent],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [DS.Color.accentCyan, DS.Color.accent],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Modern Readout

/// Clean rounded counter text.
struct Readout: View {
    let text: String
    var large = false

    var body: some View {
        Text(text)
            .font(large ? DS.Font.counterLarge : DS.Font.counter)
            .foregroundStyle(DS.Color.ink)
    }
}
