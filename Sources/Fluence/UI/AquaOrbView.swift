import SwiftUI
import AppKit

/// The iconic Aqua Voice glowing translucent orb.
///
/// Reproduces the Aqua Voice artistic style:
/// Luminous cyan/aqua sphere with multi-layer specular highlights and dynamic breathing pulse.
struct AquaOrbView: View {
    var size: CGFloat = 26
    var isActive: Bool = false
    var isListening: Bool = false

    @State private var pulse: Bool = false

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
                    .scaleEffect(pulse ? 1.15 : 0.95)
                    .opacity(pulse ? 0.9 : 0.4)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            }

            // Orb Core (Image or Procedural glossy glass sphere)
            if let orbImage = loadOrbImage() {
                Image(nsImage: orbImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .shadow(color: Color(hex: 0x0084FF).opacity(isActive ? 0.5 : 0.25), radius: isActive ? 6 : 3, y: 1)
            } else {
                proceduralOrb
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            pulse = true
        }
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

    private func loadOrbImage() -> NSImage? {
        if let img = NSImage(named: "AquaOrb") { return img }
        if let img = NSImage(named: "AppIcon") { return img }
        if let bundleURL = Bundle.main.url(forResource: "AquaOrb", withExtension: "png"),
           let img = NSImage(contentsOf: bundleURL) {
            return img
        }
        if let bundleURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: bundleURL) {
            return img
        }
        return nil
    }
}
