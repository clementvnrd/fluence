import Foundation

/// WCAG 2.x contrast between two opaque sRGB colours (FLU-38), so the design system's text and
/// focus colours are checked by a test rather than by eye.
///
/// AA asks for 4.5:1 for text (3:1 only for large text, ≥ 18 pt or ≥ 14 pt bold — Fluence's text
/// is smaller) and 3:1 for the parts of a control or an icon one needs to see (WCAG 1.4.11), such
/// as a focus ring.
public enum ColorContrast {
    /// Body text, captions, labels.
    public static let textMinimum = 4.5
    /// A focus ring, an icon that carries meaning, a control's boundary.
    public static let nonTextMinimum = 3.0

    /// Relative luminance of a `0xRRGGBB` sRGB colour, 0 (black) … 1 (white).
    public static func luminance(_ hex: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let value = Double(channel & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(hex >> 16) + 0.7152 * linear(hex >> 8) + 0.0722 * linear(hex)
    }

    /// The contrast ratio, 1 … 21, whichever colour is lighter.
    public static func ratio(_ first: UInt32, _ second: UInt32) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `foreground` at `opacity` drawn over `background`, as a tint fill is (a badge's 12 % green).
    /// Blended per channel on the encoded sRGB values, as the window's compositing does.
    public static func blend(_ foreground: UInt32, opacity: Double, over background: UInt32) -> UInt32 {
        var result: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let top = Double((foreground >> shift) & 0xFF)
            let bottom = Double((background >> shift) & 0xFF)
            let mixed = (top * opacity + bottom * (1 - opacity)).rounded()
            result |= UInt32(min(255, max(0, mixed))) << shift
        }
        return result
    }
}
