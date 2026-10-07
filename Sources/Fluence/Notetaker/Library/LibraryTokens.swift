import SwiftUI

// Tokens for the meetings library. Kept in an extension of `DS` beside the feature, so
// the shared design-system file is not edited by two branches at once; they follow the
// same rules and may be folded into DesignSystem.swift at merge.
extension DS {
    enum Library {
        // Window
        static let minWidth: CGFloat = 860
        static let minHeight: CGFloat = 560
        /// The meetings list column.
        static let listWidth: CGFloat = 290
        /// The rename / edit sheets.
        static let sheetWidth: CGFloat = 420
        /// The settings window once it holds the Meetings section.
        static let settingsWidth: CGFloat = 560
        static let settingsHeight: CGFloat = 640

        // Glyphs on small keys and rows, matching the existing 9–10 pt symbols.
        static let glyph: CGFloat = 9
        static let glyphLarge: CGFloat = 10
        /// Lamps in list rows and status lines.
        static let lampSmall: CGFloat = 6
        /// Optical nudge so a lamp sits on the first text baseline.
        static let lampBaselineNudge: CGFloat = 3

        // Ink on the deck at reduced strength, the way the existing lists dim secondary text.
        static let inkDim: Double = 0.6
        static let inkFaint: Double = 0.45
        static let edgeFaint: Double = 0.3

        /// Width of the timestamp column in the transcript, so text aligns.
        static let timestampWidth: CGFloat = 64
        /// Minimum height of the "My notes" editor.
        static let editorMinHeight: CGFloat = 220
        /// How long "Copied" stays on a key.
        static let flashDuration: Duration = .seconds(1.4)
        /// Pause after typing before the encrypted search runs.
        static let searchDebounce: Duration = .milliseconds(250)
    }
}
