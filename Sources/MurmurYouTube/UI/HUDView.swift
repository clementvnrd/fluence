import SwiftUI

/// Understated, elegant floating capsule HUD.
///
/// Designed with a minimalist Apple aesthetic: obsidian glass, delicate hairline border,
/// pure monochrome audio visualizer, and crisp typography without garish AI clichés.
struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        ZStack {
            // Margin clearance for soft diffused shadows
            Color.clear
                .frame(width: 520, height: 100)

            // Luminous Aqua Voice floating capsule
            HStack(spacing: 12) {
                // The iconic Aqua Voice Orb
                AquaOrbView(
                    size: 24,
                    isActive: controller.state.isActive,
                    isListening: controller.state == .listening
                )

                // Clean vibrant Aqua waveform
                AquaWaveform(level: controller.level, isActive: controller.state == .listening)
                    .frame(width: 48, height: 20)

                // Spoken text / Status label
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.12), value: controller.transcript)

                // Quick Language Switcher Pill (FR / EN / AUTO)
                if Settings.shared.engine != .parakeet {
                    Button {
                        Settings.shared.toggleLanguage()
                    } label: {
                        Text(Settings.shared.language.shortDisplay)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(DS.Color.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(DS.Color.selection, in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(DS.Color.selectionEdge, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Cliquer pour basculer de langue (ou ⌥L)")
                }

                // Finish / Validate checkmark button when active
                if controller.state.isActive {
                    Button {
                        controller.stopButtonRecording()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(DS.Color.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Terminer la dictée")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(width: 430, height: 48)
            .background {
                Capsule()
                    .fill(DS.Color.panel.opacity(0.95))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.7),
                                        Color(hex: 0x38BDF8).opacity(controller.state.isActive ? 0.45 : 0.15),
                                        Color.white.opacity(0.3)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.75
                            )
                    )
                    .shadow(
                        color: Color(hex: 0x0084FF).opacity(controller.state.isActive ? 0.35 : 0.08),
                        radius: controller.state.isActive ? 20 : 10,
                        x: 0,
                        y: 5
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
            }
        }
    }

    private var label: String {
        switch controller.state {
        case .starting:
            return controller.isCommandMode ? "Mode Commande…" : "Écoute…"
        case .listening:
            if controller.transcript.isEmpty {
                return controller.isCommandMode ? "Énoncez votre commande…" : "Parlez maintenant…"
            }
            return controller.isCommandMode ? "CMD: \(controller.transcript)" : controller.transcript
        case .finishing:
            if controller.isCommandMode {
                return controller.transcript.isEmpty ? "Application…" : "CMD: \(controller.transcript)"
            }
            return controller.transcript.isEmpty ? "Transcription…" : controller.transcript
        case .error(let message):
            return message
        case .idle:
            return "Fluence • Prêt"
        }
    }
}

/// Luminous Aqua Voice audio meter waveform bars.
private struct AquaWaveform: View {
    let level: Float
    let isActive: Bool

    private static let barCount = 7
    private static let phases: [Double] = (0..<barCount).map { index in
        (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(barGradient(for: index))
                        .frame(width: 2.5, height: height(for: index, at: t))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func barGradient(for index: Int) -> LinearGradient {
        guard isActive else {
            return LinearGradient(
                colors: [Color(hex: 0x0084FF).opacity(0.25), Color(hex: 0x0EA5E9).opacity(0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color(hex: 0x38BDF8), Color(hex: 0x0084FF)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func height(for index: Int, at time: TimeInterval) -> CGFloat {
        let floorHeight: CGFloat = 3.5
        guard isActive else { return floorHeight }

        let phase = Self.phases[index]
        let wave = sin(time * 6.5 + phase * .pi * 2)
        let amplitude = CGFloat(max(0.08, level))
        let scaled = amplitude * (0.65 + 0.35 * CGFloat(wave))
        return min(18, floorHeight + max(0, scaled) * 16)
    }
}
