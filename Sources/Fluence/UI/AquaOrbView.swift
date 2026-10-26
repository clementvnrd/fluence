import SwiftUI
import AppKit

/// Fluence's mark: a drawn glass sphere, luminous blue to cyan, with specular highlights and
/// a breathing halo while listening. Used for the sidebar, settings, onboarding and HUD
/// (FLU-12 decision 4); the Dock icon is `AppIcon.icns`.
struct AquaOrbView: View {
    var size: CGFloat = 26
    var isActive: Bool = false
    var isListening: Bool = false

    @State private var pulse: Bool = false
    /// Reduce Motion (FLU-38): the halo stays lit, still, between its two pulse states.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Luminous Aqua Pulse Halo when active
            if isActive || isListening {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: 0x38BDF8).opacity(0.55),
                                Color(hex: 0x0084FF).opacity(0.25),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: size * 0.3,
                            endRadius: size * 0.95
                        )
                    )
                    .frame(width: size * 1.8, height: size * 1.8)
                    .scaleEffect(reduceMotion ? 1.05 : (pulse ? 1.15 : 0.95))
                    .opacity(reduceMotion ? 0.65 : (pulse ? 0.9 : 0.4))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            }

            // FLU-12 decision 4: the drawn glass sphere everywhere the brand mark appears —
            // not the app-icon artwork, which stays the Dock icon only.
            proceduralOrb
        }
        .frame(width: size, height: size)
        .onAppear {
            pulse = !reduceMotion
        }
        // Turned on while the orb shows: end the running pulse rather than let it repeat.
        .onChange(of: reduceMotion) { pulse = !reduceMotion }
    }

    private var proceduralOrb: some View {
        ZStack {
            // Base sphere with rich aqua depth
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: 0x38BDF8),
                            Color(hex: 0x0084FF),
                            Color(hex: 0x0369A1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Inner glow and ambient highlight
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.65),
                            Color(hex: 0x38BDF8).opacity(0.2),
                            Color.clear
                        ],
                        center: .init(x: 0.32, y: 0.28),
                        startRadius: 0,
                        endRadius: size * 0.55
                    )
                )

            // Specular reflection crescent
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.8),
                            Color.white.opacity(0.1),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(1, size * 0.05)
                )
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: 0x0084FF).opacity(isActive ? 0.55 : 0.28), radius: isActive ? 7 : 3.5, y: 1.5)
    }
}
