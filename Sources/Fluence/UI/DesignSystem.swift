import FluenceCore
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

    // MARK: - Colour

    /// Every colour comes from `DesignPalette` (FluenceCore), the table `DesignContrastTests`
    /// checks against WCAG AA (FLU-38): add or change a colour there, never as a hex here.
    enum Color {
        typealias P = DesignPalette

        /// Base window canvas: Luminous paper mist in light, deep midnight slate in dark.
        static let chassis = face(P.chassis)

        /// Elevated card surface: Pure crisp white in light, deep slate in dark.
        static let panel = face(P.panel)

        /// Top border highlight on cards.
        static let panelHighlight = face(P.panelHighlight)

        /// Card shade.
        static let panelShade = face(P.panelShade)

        /// Recessed content wells and search bars.
        static let well = face(P.well)

        /// Floating decks and popovers.
        static let deck = face(P.deck)

        /// Button and interactive control surface.
        static let cap = face(P.cap)

        /// Subtle dividers and hairline borders.
        static let seam = face(P.seam)

        // Text
        /// Primary high-contrast text: Deep ink in light, pure white in dark.
        static let ink = face(P.ink)
        /// Secondary supporting text.
        static let inkSecondary = face(P.inkSecondary)
        /// Section headers and label tags.
        static let silkscreen = face(P.silkscreen)
        /// Text on dark surfaces.
        static let inkOnDeck = face(P.inkOnDeck)

        // Aqua Voice Signature Accents
        /// Vibrant electric aqua blue.
        static let accent = face(P.accent)
        /// Luminous cyan / light aqua.
        static let accentCyan = face(P.accentCyan)
        /// Recording indicator (glowing electric aqua / coral red).
        static let record = face(P.record)
        static let recordRed = face(P.recordRed)
        static let recordIdle = face(P.recordIdle)
        /// A meeting being recorded: the dot, the banner, the pill, *Arrêter*, the sidebar dot.
        /// The only recording that is red (FLU-12 decision 3); a dictation uses `record`.
        static let meetingRecord = recordRed
        /// Destructive actions (*Supprimer*, *Tout effacer*): same red, a different meaning.
        static let destructive = recordRed

        // Selection & Hover
        static let selection = face(P.selection)
        static let selectionEdge = face(P.selectionEdge)
        /// The keyboard focus ring (FLU-38): the accent, 2 pt, outside the control.
        static let focusRing = face(P.focusRing)
        static let hover = face(P.hover)
        /// The soft blue shadow under the *Dicter* pill and the active HUD.
        static let aquaGlow = face(P.aquaGlow)

        // Status that is neither recording nor instrumentation.
        /// "This is on / available" — a lit status dot.
        static let pilot = face(P.pilot)
        /// Fault markers (icons, dots). Error *text* uses `faultText`.
        static let fault = face(P.fault)

        // Status text (FLU-38): darker in light mode so words reach 4.5:1. Dots, icons and
        // tints keep the bright `meterAmber` / `meterGreen` / `fault`.
        /// Amber words: `RowNote` caveats, notices, a warning `GrantBadge`.
        static let amberText = face(P.amberText)
        /// Green words: the « Autorisé » `GrantBadge`.
        static let greenText = face(P.greenText)
        /// Red error words.
        static let faultText = face(P.faultText)

        // Instrumentation / Meter
        static let meterFace = face(P.meterFace)
        static let meterLamp = face(P.meterLamp)
        static let meterNeedle = face(P.meterNeedle)
        static let meterGreen = face(P.meterGreen)
        static let meterAmber = face(P.meterAmber)
        static let meterRed = face(P.meterRed)

        // MARK: - Helpers

        /// A token as a colour. A fixed one does not change with the appearance; the others are
        /// resolved by AppKit on every draw, so a window follows an appearance change at once.
        private static func face(_ token: ColorToken) -> SwiftUI.Color {
            if token.isFixed { return SwiftUI.Color(hex: token.light) }
            return SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: token.value(isDark: isDark))
            })
        }
    }

    // MARK: - Materials

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

    // MARK: - Corner radii

    enum Radius {
        static let none: CGFloat = 0
        static let chip: CGFloat = 6
        static let control: CGFloat = 10
        static let panel: CGFloat = 16
        static let window: CGFloat = 18
        static let pill: CGFloat = 999
    }

    // MARK: - Borders

    enum Border {
        static let hairline: CGFloat = 0.75
        static let seam: CGFloat = 1
        static let bevel: CGFloat = 1
    }

    // MARK: - Shadows

    enum Shadow {
        static let raised = Spec(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
        static let pressed = Spec(color: .black.opacity(0.02), radius: 2, x: 0, y: 1)
        static let panel = Spec(color: .black.opacity(0.05), radius: 14, x: 0, y: 4)
        static let window = Spec(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
        static let glow = Spec(color: Color.aquaGlow.opacity(0.22), radius: 12, x: 0, y: 3)

        /// One drop shadow, read field by field by `.shadow(color:radius:x:y:)`.
        struct Spec {
            let color: SwiftUI.Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
    }

    // MARK: - Focus

    /// The keyboard focus ring (FLU-38): 2 pt in the accent colour, 3 pt outside the control,
    /// no glow, only while the keyboard moves the focus.
    enum Focus {
        static let ringWidth: CGFloat = 2
        static let ringOffset: CGFloat = 3
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
    /// The menu bar icon (FLU-80): the symbol size SwiftUI gives a menu bar label, so the
    /// icon drawn with the update dot matches the plain one, and the dot itself.
    enum MenuBar {
        static let symbolSize: CGFloat = 13
        static let dotSize: CGFloat = 6
        /// Clear ring between the dot and the symbol.
        static let dotRing: CGFloat = 1.5
    }

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
        static let aqua = DesignPalette.aquaGradient.map { SwiftUI.Color(hex: $0) }
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

// MARK: - Colours from hex

extension SwiftUI.Color {
    /// A 24-bit `0xRRGGBB` value in sRGB, fully opaque.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    /// A 24-bit `0xRRGGBB` value in sRGB, fully opaque.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
