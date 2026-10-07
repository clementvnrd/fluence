import SwiftUI

// Tokens for the FLU-5 text features (cleanup levels, languages, styles, snippets,
// auto-learn). Kept in an extension of `DS` beside the feature, like `DS.Library`, so the
// shared design-system file isn't edited by two branches at once.
extension DS {
    enum Parity {
        /// The snippet and learned-word editors.
        static let sheetWidth: CGFloat = 460
        /// Minimum height of the snippet text editor.
        static let editorMinHeight: CGFloat = 120
        /// Width of the category column in the styles panel, so the keys line up.
        static let categoryColumn: CGFloat = 132
        /// A snippet's expansion is previewed on this many lines in the list.
        static let previewLines = 2
        /// The kind tag column, matching the dictionary rows.
        static let tagColumn: CGFloat = 34
        /// Glyphs on small keys, matching the existing 9 pt symbols.
        static let glyph: CGFloat = 9
        /// Secondary ink on the deck, as in the dictionary and history lists.
        static let inkDim: Double = 0.6
        static let inkFaint: Double = 0.45
        static let edgeFaint: Double = 0.3
    }
}
