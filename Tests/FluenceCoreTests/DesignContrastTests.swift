import Testing

@testable import FluenceCore

/// FLU-38: every text and focus colour of the design system against the surfaces it is drawn
/// on, light and dark, at WCAG AA — 4.5:1 for text, 3:1 for a focus ring or an icon that
/// carries meaning. `DS.Color` in the app reads the same `DesignPalette`, so this is the check
/// on what the app draws.
///
/// The pairs Clement chose to keep below the bar are listed in `knownExceptions` with his
/// reason, and checked to still be below it: an exception that starts passing must leave the
/// list, so the list never hides a pair nobody looks at.
struct DesignContrastTests {
    typealias P = DesignPalette

    enum Kind: String, Sendable {
        case text, nonText

        var minimum: Double { self == .text ? ColorContrast.textMinimum : ColorContrast.nonTextMinimum }
    }

    enum Appearance: String, Sendable, CaseIterable {
        case light, dark

        var isDark: Bool { self == .dark }
    }

    struct Pair: Sendable, CustomTestStringConvertible {
        let use: String
        let foreground: ColorToken
        let background: ColorToken
        var kind: Kind = .text
        var appearances: [Appearance] = Appearance.allCases

        func ratio(_ appearance: Appearance) -> Double {
            ColorContrast.ratio(foreground.value(isDark: appearance.isDark), background.value(isDark: appearance.isDark))
        }

        var testDescription: String { use }
    }

    /// A status colour's tint fill (12 %) over a card, the background of its own text.
    static func tint(_ color: ColorToken, over surface: ColorToken = P.panel) -> ColorToken {
        ColorToken(
            light: ColorContrast.blend(color.light, opacity: P.statusTintOpacity, over: surface.light),
            dark: ColorContrast.blend(color.dark, opacity: P.statusTintOpacity, over: surface.dark)
        )
    }

    /// A hovered sidebar row: the well at 70 % over the canvas.
    static let sidebarHover = ColorToken(
        light: ColorContrast.blend(P.well.light, opacity: 0.7, over: P.chassis.light),
        dark: ColorContrast.blend(P.well.dark, opacity: 0.7, over: P.chassis.dark)
    )

    static let white = ColorToken.fixed(0xFFFFFF)

    /// What the app draws, foreground on background.
    static let pairs: [Pair] = {
        var pairs: [Pair] = []
        let surfaces: [(String, ColorToken)] = [
            ("canvas", P.chassis), ("card", P.panel), ("well", P.well), ("button", P.cap),
            ("popover", P.deck), ("hovered card", P.hover),
        ]
        for (name, surface) in surfaces + [("selection", P.selection)] {
            pairs.append(Pair(use: "ink on \(name)", foreground: P.ink, background: surface))
            pairs.append(Pair(use: "inkSecondary (timestamps, subtitles, chips) on \(name)", foreground: P.inkSecondary, background: surface))
        }
        for (name, surface) in surfaces where name != "hovered card" {
            pairs.append(Pair(use: "silkscreen (group labels, counts, ⓘ, ⌘F) on \(name)", foreground: P.silkscreen, background: surface))
        }
        pairs.append(Pair(use: "silkscreen (sidebar count) on a hovered sidebar row", foreground: P.silkscreen, background: sidebarHover))

        // Status text: the -Text tokens; the bright meter colours stay for dots, icons, tints.
        for (name, surface) in [("canvas", P.chassis), ("card", P.panel), ("popover", P.deck)] {
            pairs.append(Pair(use: "amberText (RowNote, notices) on \(name)", foreground: P.amberText, background: surface))
        }
        for (name, surface) in [("canvas", P.chassis), ("card", P.panel), ("well (snippet list footer)", P.well)] {
            pairs.append(Pair(use: "faultText (error notes) on \(name)", foreground: P.faultText, background: surface))
        }
        pairs.append(Pair(use: "amberText on its tint (GrantBadge warning)", foreground: P.amberText, background: tint(P.meterAmber)))
        pairs.append(Pair(use: "greenText on its tint (GrantBadge « Autorisé »)", foreground: P.greenText, background: tint(P.meterGreen)))

        // The keyboard focus ring sits outside the control, on whatever surrounds it.
        for (name, surface) in surfaces + [("selection", P.selection), ("hovered sidebar row", sidebarHover)] {
            pairs.append(Pair(use: "focus ring around a control on \(name)", foreground: P.focusRing, background: surface, kind: .nonText))
        }
        // The switch when on, and accent icons (settings rows, sidebar).
        for (name, surface) in [("card", P.panel), ("canvas", P.chassis), ("selection", P.selection)] {
            pairs.append(Pair(use: "accent icon / switch on \(name)", foreground: P.accent, background: surface, kind: .nonText))
        }
        return pairs
    }()

    /// Kept below the bar on purpose. Each says who decided it and why.
    static let knownExceptions: [Pair] = {
        var pairs: [Pair] = []
        // Clement, 2026-10-26: « le bleu reste tel quel » — the accent, the Dicter gradient,
        // the AI badge and the filled buttons are the Aqua identity.
        pairs.append(Pair(use: "white on the accent (PrimaryButton, « Ajouter » on the HUD)", foreground: white, background: P.accent))
        for (index, stop) in P.aquaGradient.enumerated() {
            pairs.append(Pair(
                use: "white on the Aqua gradient, stop \(index) (Dicter, AI badge)",
                foreground: white, background: .fixed(stop), appearances: [.light]
            ))
        }
        for (name, surface) in [("card", P.panel), ("well", P.well), ("selection", P.selection)] {
            pairs.append(Pair(
                use: "accent text (AccentChip, KeyCap, selected count, engaged button) on \(name)",
                foreground: P.accent, background: surface, appearances: [.light]
            ))
        }
        // Clement, 2026-10-26: dots, icons and tints keep the bright status colours; the
        // words next to them carry the meaning, in amberText / greenText.
        pairs.append(Pair(use: "amber warning icon on a card", foreground: P.meterAmber, background: P.panel, kind: .nonText, appearances: [.light]))
        pairs.append(Pair(use: "amber warning icon on its banner tint", foreground: P.meterAmber, background: tint(P.meterAmber), kind: .nonText, appearances: [.light]))
        pairs.append(Pair(use: "green status dot on a well (StatusChip)", foreground: P.meterGreen, background: P.well, kind: .nonText, appearances: [.light]))
        return pairs
    }()

    @Test("text and focus colours reach AA", arguments: pairs)
    func reachesAA(_ pair: Pair) {
        for appearance in pair.appearances {
            let ratio = pair.ratio(appearance)
            #expect(
                ratio >= pair.kind.minimum,
                "\(pair.use), \(appearance.rawValue): \(String(format: "%.2f", ratio)):1 < \(pair.kind.minimum):1"
            )
        }
    }

    @Test("a known exception is still below the bar, or it leaves the list", arguments: knownExceptions)
    func exceptionIsStillAnException(_ pair: Pair) {
        for appearance in pair.appearances {
            #expect(pair.ratio(appearance) < pair.kind.minimum, "\(pair.use), \(appearance.rawValue) passes now")
        }
    }

    @Test("the blue is Clement's and stays as it is")
    func blueUnchanged() {
        #expect(P.accent == ColorToken(light: 0x0084FF, dark: 0x38BDF8))
        #expect(P.aquaGradient == [0x38BDF8, 0x0084FF])
        // The ring is the accent itself, in both appearances.
        #expect(P.focusRing == P.accent)
    }

    @Test("the contrast formula matches WCAG's reference values")
    func formula() {
        #expect(ColorContrast.ratio(0x000000, 0xFFFFFF) == 21)
        #expect(ColorContrast.ratio(0xFFFFFF, 0xFFFFFF) == 1)
        // Symmetric, and the classic #777 on white sits just under AA.
        #expect(ColorContrast.ratio(0x777777, 0xFFFFFF) == ColorContrast.ratio(0xFFFFFF, 0x777777))
        #expect(abs(ColorContrast.ratio(0x777777, 0xFFFFFF) - 4.48) < 0.01)
        #expect(abs(ColorContrast.ratio(0x0084FF, 0xFFFFFF) - 3.66) < 0.01)
    }

    @Test("a tint is blended over its surface")
    func blend() {
        #expect(ColorContrast.blend(0x10B981, opacity: 0.12, over: 0xFFFFFF) == 0xE2F7F0)
        #expect(ColorContrast.blend(0x123456, opacity: 1, over: 0xFFFFFF) == 0x123456)
        #expect(ColorContrast.blend(0x123456, opacity: 0, over: 0xABCDEF) == 0xABCDEF)
    }
}
