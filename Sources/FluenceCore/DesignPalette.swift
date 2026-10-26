/// The design system's colours as plain `0xRRGGBB` sRGB values, light and dark (FLU-38).
///
/// `DS.Color` in the app reads every colour from here, and `DesignContrastTests` computes the
/// contrast of every text and focus colour on the surfaces it is drawn on: the two read the
/// same table, so a token cannot change in the app without the test seeing it.
public struct ColorToken: Sendable, Equatable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    /// The same colour in both appearances.
    public static func fixed(_ hex: UInt32) -> ColorToken {
        ColorToken(light: hex, dark: hex)
    }

    public var isFixed: Bool { light == dark }

    public func value(isDark: Bool) -> UInt32 { isDark ? dark : light }
}

public enum DesignPalette {
    // Surfaces
    /// Base window canvas: paper mist in light, deep midnight slate in dark.
    public static let chassis = ColorToken(light: 0xF8FAFC, dark: 0x0B0F17)
    /// Elevated card surface.
    public static let panel = ColorToken(light: 0xFFFFFF, dark: 0x131B2A)
    public static let panelHighlight = ColorToken(light: 0xFFFFFF, dark: 0x1E293B)
    public static let panelShade = ColorToken(light: 0xF1F5F9, dark: 0x0E1624)
    /// Recessed wells and search bars.
    public static let well = ColorToken(light: 0xF1F5F9, dark: 0x0E1522)
    /// Floating decks and popovers.
    public static let deck = ColorToken(light: 0xFFFFFF, dark: 0x162032)
    /// Button surface.
    public static let cap = ColorToken(light: 0xFFFFFF, dark: 0x1A2436)
    /// Hairline borders.
    public static let seam = ColorToken(light: 0xE2E8F0, dark: 0x1E293B)

    // Text
    public static let ink = ColorToken(light: 0x0F172A, dark: 0xF8FAFC)
    /// FLU-38: light #64748B → #56657B (4.34 → 5.41:1 on the well).
    public static let inkSecondary = ColorToken(light: 0x56657B, dark: 0x94A3B8)
    /// Group labels, counts, day headers, ⓘ, ⌘F. FLU-38: #94A3B8 / #64748B → #5E6E84 / #7F8DA3
    /// (2.56 → 5.20:1 on a light card, 3.62 → 5.12:1 on a dark one).
    public static let silkscreen = ColorToken(light: 0x5E6E84, dark: 0x7F8DA3)
    public static let inkOnDeck = ColorToken(light: 0x0F172A, dark: 0xF8FAFC)

    // Accent (unchanged by FLU-38: Clement keeps the blue as it is)
    public static let accent = ColorToken(light: 0x0084FF, dark: 0x38BDF8)
    public static let accentCyan = ColorToken(light: 0x0EA5E9, dark: 0x38BDF8)
    public static let record = ColorToken(light: 0x0084FF, dark: 0x38BDF8)
    public static let recordRed = ColorToken.fixed(0xEF4444)
    public static let recordIdle = ColorToken(light: 0x94A3B8, dark: 0x475569)

    // Selection and hover
    public static let selection = ColorToken(light: 0xE0F2FE, dark: 0x162C46)
    public static let selectionEdge = ColorToken(light: 0x7DD3FC, dark: 0x0EA5E9)
    /// The keyboard focus ring (FLU-38): the accent itself, so it follows the dark accent too.
    public static let focusRing = accent
    public static let hover = ColorToken(light: 0xF8FAFC, dark: 0x1C283C)
    /// The soft blue shadow under the *Dicter* pill and the active HUD.
    public static let aquaGlow = ColorToken.fixed(0x0084FF)

    // Status
    public static let pilot = ColorToken(light: 0x0084FF, dark: 0x38BDF8)
    public static let fault = ColorToken.fixed(0xEF4444)

    // Meter
    public static let meterFace = ColorToken(light: 0xF1F5F9, dark: 0x0E1522)
    public static let meterLamp = ColorToken.fixed(0x0084FF)
    public static let meterNeedle = ColorToken(light: 0x0F172A, dark: 0xF8FAFC)
    public static let meterGreen = ColorToken.fixed(0x10B981)
    public static let meterAmber = ColorToken.fixed(0xF59E0B)
    public static let meterRed = ColorToken.fixed(0xEF4444)

    // Status *text*. The bright meter colours above stay for dots, icons and tints.
    /// Amber words: `RowNote` caveats, warning notices, a warning `GrantBadge`.
    public static let amberText = ColorToken(light: 0xB45309, dark: 0xF59E0B)
    /// Green words: the « Autorisé » `GrantBadge`.
    public static let greenText = ColorToken(light: 0x047857, dark: 0x10B981)
    /// Red error words. `fault` stays for markers; `meetingRecord` red is untouched.
    public static let faultText = ColorToken(light: 0xB91C1C, dark: 0xEF4444)

    /// The Aqua gradient (orb, level bars, the AI badge and *Dicter*), top stop first.
    public static let aquaGradient: [UInt32] = [0x38BDF8, 0x0084FF]

    /// Opacity of a status tint fill under its own text (`GrantBadge`).
    public static let statusTintOpacity = 0.12
}
