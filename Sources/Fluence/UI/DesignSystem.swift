import SwiftUI

/// Refined macOS Design System — Clement's Fluence look.
///
/// Direction: Pure, understated native macOS craftsmanship (Things 3 / Apple Notes style).
/// No generic "AI" gradients or neon glows. Rich, deep Dark Mode and clean, warm Light Mode.
///
/// Light paper-mist canvas, rounded white cards with hairline borders and soft shadows, one
/// electric-blue accent (the Aqua orb's colour). The blue-to-cyan gradient is reserved for
/// the Aqua identity — the orb, the "AI" badge and the primary *Dicter* button. Red marks a
/// *meeting* recording (FLU-12 decision 3) and destructive actions; dictation stays blue.
/// Amber and green are status (warnings, granted), never chrome.
enum DS {

    // MARK: - Color

    enum Color {
        /// Base window canvas: Luminous paper mist in light, deep midnight slate in dark.
        static let chassis = face(light: 0xF8FAFC, dark: 0x0B0F17)

        /// Elevated card surface: Pure crisp white in light, deep slate in dark.
        static let panel = face(light: 0xFFFFFF, dark: 0x131B2A)

        /// Top border highlight on cards.
        static let panelHighlight = face(light: 0xFFFFFF, dark: 0x1E293B)

        /// Card shade.
        static let panelShade = face(light: 0xF1F5F9, dark: 0x0E1624)

        /// Recessed content wells and search bars.
        static let well = face(light: 0xF1F5F9, dark: 0x0E1522)

        /// Floating decks and popovers.
        static let deck = face(light: 0xFFFFFF, dark: 0x162032)

        /// Button and interactive control surface.
        static let cap = face(light: 0xFFFFFF, dark: 0x1A2436)

        /// Subtle dividers and hairline borders.
        static let seam = face(light: 0xE2E8F0, dark: 0x1E293B)

        // Text
        /// Primary high-contrast text: Deep ink in light, pure white in dark.
        static let ink = face(light: 0x0F172A, dark: 0xF8FAFC)
        /// Secondary supporting text.
        static let inkSecondary = face(light: 0x64748B, dark: 0x94A3B8)
        /// Section headers and label tags.
        static let silkscreen = face(light: 0x94A3B8, dark: 0x64748B)
        /// Text on dark surfaces.
        static let inkOnDeck = face(light: 0x0F172A, dark: 0xF8FAFC)

        // Aqua Voice Signature Accents
        /// Vibrant electric aqua blue.
        static let accent = face(light: 0x0084FF, dark: 0x38BDF8)
        /// Luminous cyan / light aqua.
        static let accentCyan = face(light: 0x0EA5E9, dark: 0x38BDF8)
        /// Recording indicator (glowing electric aqua / coral red).
        static let record = face(light: 0x0084FF, dark: 0x38BDF8)
        static let recordRed = swatch(0xEF4444)
        static let recordIdle = face(light: 0x94A3B8, dark: 0x475569)
        /// A meeting being recorded: the dot, the banner, the pill, *Arrêter*, the sidebar dot.
        /// The only recording that is red (FLU-12 decision 3); a dictation uses `record`.
        static let meetingRecord = recordRed
        /// Destructive actions (*Supprimer*, *Tout effacer*): same red, a different meaning.
        static let destructive = recordRed

        // Selection & Hover
        static let selection = face(light: 0xE0F2FE, dark: 0x162C46)
        static let selectionEdge = face(light: 0x7DD3FC, dark: 0x0EA5E9)
        static let focusRing = swatch(0x0084FF)
        static let hover = face(light: 0xF8FAFC, dark: 0x1C283C)

        // Status that is neither recording nor instrumentation.
        /// "This is on / available" — a lit status dot.
        static let pilot = face(light: 0x0084FF, dark: 0x38BDF8)
        /// Error text and fault markers.
        static let fault = swatch(0xEF4444)

        // Instrumentation / Meter
        static let meterFace = face(light: 0xF1F5F9, dark: 0x0E1522)
        static let meterLamp = swatch(0x0084FF)
        static let meterNeedle = face(light: 0x0F172A, dark: 0xF8FAFC)
        static let meterGreen = swatch(0x10B981)
        static let meterAmber = swatch(0xF59E0B)
        static let meterRed = swatch(0xEF4444)

        // MARK: - Helpers

        private static func swatch(_ hex: UInt32) -> SwiftUI.Color { SwiftUI.Color(hex: hex) }

        private static func face(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
        }
    }

    // MARK: - Material

    enum Material {
        static let grainLight: Double = 0.0
        static let grainDark: Double = 0.0
        static let grainPitch: CGFloat = 0
        static let grainAngle: Angle = .degrees(0)

        static let screwSize: CGFloat = 0
        static let screwInset: CGFloat = 0

        static let ventSlotWidth: CGFloat = 2
        static let ventSlotHeight: CGFloat = 12
        static let ventSlotGap: CGFloat = 3
        static let ventRadius: CGFloat = 1

        static let lampSize: CGFloat = 8
        static let lampSpecular: Double = 0.5
        static let lampUnlitOpacity: Double = 0.3

        static let segmentThickness: CGFloat = 2
        static let segmentGap: CGFloat = 1
        static let segmentGhostOpacity: Double = 0.0

        static let keyHeight: CGFloat = 32
        static let keyMinWidth: CGFloat = 52
        static let keyTravel: CGFloat = 1.0

        static let needleSweep: Angle = .degrees(90)
        static let needleWidth: CGFloat = 1.5
        static let meterZeroPoint: Double = 0.75
    }

    // MARK: - Type

    enum Font {
        static let silkscreen = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let silkscreenLarge = SwiftUI.Font.system(size: 12, weight: .semibold)

        static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        static let label = SwiftUI.Font.system(size: 12, weight: .medium)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let bodyEmphasis = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 16, weight: .semibold)

        static let counter = SwiftUI.Font.system(size: 13, weight: .medium, design: .rounded).monospacedDigit()
        static let counterLarge = SwiftUI.Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()

        static let silkscreenTracking: CGFloat = 0.2
    }

    // MARK: - Spacing

    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 8
        static let base: CGFloat = 12
        static let roomy: CGFloat = 16
        static let wide: CGFloat = 20
        static let panel: CGFloat = 24
    }

    // MARK: - Radius

    enum Radius {
        static let none: CGFloat = 0
        static let chip: CGFloat = 6
        static let control: CGFloat = 10
        static let panel: CGFloat = 16
        static let window: CGFloat = 18
        static let pill: CGFloat = 999
    }

    // MARK: - Border

    enum Border {
        static let hairline: CGFloat = 0.75
        static let seam: CGFloat = 1
        static let bevel: CGFloat = 1
    }

    // MARK: - Elevation

    enum Shadow {
        static let raised = Spec(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
        static let pressed = Spec(color: .black.opacity(0.02), radius: 2, x: 0, y: 1)
        static let panel = Spec(color: .black.opacity(0.05), radius: 14, x: 0, y: 4)
        static let window = Spec(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
        static let glow = Spec(color: SwiftUI.Color(hex: 0x0084FF).opacity(0.22), radius: 12, x: 0, y: 3)

        struct Spec {
            let color: SwiftUI.Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
    }

    // MARK: - Motion

    enum Motion {
        static let press = Animation.easeOut(duration: 0.08)
        static let release = Animation.spring(response: 0.22, dampingFraction: 0.75)
        static let panel = Animation.spring(response: 0.28, dampingFraction: 0.85)
        static let lamp = Animation.easeInOut(duration: 0.12)
        /// A readout's text changing as the transcript is revised.
        static let readout = Animation.easeOut(duration: 0.12)

        static let needleAttack: TimeInterval = 0.15
        static let needleRelease: TimeInterval = 0.25
        static let needleOvershoot: Double = 0.02
    }
}

// MARK: - Windows

extension DS {
    /// Fixed and minimum window sizes.
    enum Window {
        /// The main window: a sidebar and a content area (FLU-12, navigation B).
        static let main = CGSize(width: 1_100, height: 720)
        static let mainMinimum = CGSize(width: 880, height: 580)
        static let comparisonMinimum = CGSize(width: 560, height: 420)
        /// The settings window: a section list on the left, the section on the right.
        static let settings = CGSize(width: 980, height: 720)
        /// The main window's sidebar.
        static let sidebar: CGFloat = 244
        /// The settings window's section list.
        static let settingsSidebar: CGFloat = 220
        /// Room left at the top of a sidebar for the traffic lights (hidden title bar).
        static let titleBarClearance: CGFloat = 46
        /// Reading width of a meeting's notes and transcript.
        static let readingWidth: CGFloat = 760
    }

    /// Tints for people (avatars, owner chips): soft fills of the palette, never decoration.
    enum Tone {
        static let all: [SwiftUI.Color] = [
            SwiftUI.Color(hex: 0x0084FF), SwiftUI.Color(hex: 0x0EA5E9), SwiftUI.Color(hex: 0x10B981),
            SwiftUI.Color(hex: 0xD97706), SwiftUI.Color(hex: 0x64748B),
        ]
        /// The user is always blue.
        static let me = all[0]
        static let neutral = all[4]
        static let fillOpacity: Double = 0.14
    }

    /// The Aqua blue gradient: the orb, the "AI" badge and the primary action only.
    enum Gradient {
        static let aqua = [SwiftUI.Color(hex: 0x38BDF8), SwiftUI.Color(hex: 0x0084FF)]
    }

    // MARK: - HUD

    /// The floating capsule shown while dictating.
    enum HUD {
        /// A transparent canvas around the capsule, so its soft shadow is never clipped.
        static let size = CGSize(width: 580, height: 110)
        static let capsule = CGSize(width: 430, height: 48)
        /// The auto-learn offer is the one state that needs more room (two buttons).
        static let offerWidth: CGFloat = 500
        /// How long the offer stays on the capsule; it stays in the main window afterwards.
        static let offerDuration: Duration = .seconds(10)
        /// Distance above the Dock (the bottom of the visible frame).
        static let bottomOffset: CGFloat = 96
        static let fade: TimeInterval = 0.15
        static let meterFrameRate: Double = 30
    }
}

// MARK: - Notetaker (capture)

extension DS {
    /// Sizes of the Notetaker's floating panels: the *Meeting detected* card, the
    /// recording indicator and the live transcript.
    enum MeetingPanel {
        static let cardWidth: CGFloat = 360
        /// The expanded recording panel (mock-up 07, step 3).
        static let panelWidth: CGFloat = 410
        /// The compact pill's height.
        static let pillHeight: CGFloat = 36
        /// How many live lines the expanded panel shows.
        static let liveLines = 6
        static let countdownRing: CGFloat = 38
        static let recorderWidth: CGFloat = 300
        static let transcriptWidth: CGFloat = 420
        static let transcriptHeight: CGFloat = 480
        static let transcriptMinHeight: CGFloat = 200
        /// Distance from the screen's top-right corner (below the menu bar).
        static let screenInset: CGFloat = 16
        /// Width of the speaker column in the live transcript.
        static let speakerColumn: CGFloat = 64
        /// Glyph size inside a key.
        static let keyGlyph: CGFloat = 10
    }
}

// MARK: - FLU-5 input

extension DS {
    /// The first-run window that walks through the permissions.
    enum Onboarding {
        static let size = CGSize(width: 760, height: 520)
        /// The list of steps down the left side.
        static let stepColumnWidth: CGFloat = 236
        /// How often the grants are re-read. There is no notification for any of them.
        static let poll: Duration = .seconds(1)
    }
}

// MARK: - Hex helpers

extension SwiftUI.Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
