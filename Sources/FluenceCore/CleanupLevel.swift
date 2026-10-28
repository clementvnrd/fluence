import Foundation

/// How much the cleanup pass may change what was said. Wispr Flow's four levels, all on-device.
///
/// Each level contains the one below it, so a model failure at Medium or High always has a
/// meaningful fallback: the Light rules, which cannot invent anything.
public enum CleanupLevel: String, CaseIterable, Sendable, Codable {
    /// The engine's words as heard. Only the dictionary runs.
    case none
    /// Deterministic rules: fillers, spoken punctuation, spacing, capitals, final full stop.
    case light
    /// Light, then the on-device model may swap a misheard name for the dictionary's spelling
    /// (`NameFixer`, FLU-92).
    case medium
    /// Outside French, Light then the on-device model's rewrite in the style chosen for the kind
    /// of app being typed into; in French, the same as Medium (FLU-91).
    case high

    /// Whether this level runs the Foundation Models pass at all.
    public var usesModel: Bool { self == .medium || self == .high }

    /// Whether this level applies the per-app-category writing style.
    public var appliesStyle: Bool { self == .high }

    /// Whether the model may rewrite the text in the app's style: High, except in French, where
    /// that free rewrite answered or reworded dictations (FLU-91) and High fixes names instead.
    public func rewrites(in language: DictationLanguage) -> Bool {
        self == .high && !fixesNames(in: language)
    }

    /// Whether the model only swaps misheard names for the dictionary's spelling (`NameFixer`):
    /// Medium and High in French, and in Auto, which is French for most users (FLU-91/92).
    /// Other languages keep the model's cleanup, never measured as harmful there.
    public func fixesNames(in language: DictationLanguage) -> Bool {
        usesModel && (language == .french || language == .auto)
    }

    /// Where the level comes from when nothing is stored under the level's own key.
    ///
    /// Before levels existed there were two switches, `cleanupEnabled` (default on) and
    /// `smartCleanup` (default off). The mapping keeps every user's behaviour exactly as it
    /// was: off → None, on → Light, on + smart → Medium. High is new, so nobody lands there
    /// without choosing it.
    public static func migrated(cleanupEnabled: Bool?, smartCleanup: Bool?) -> CleanupLevel {
        guard cleanupEnabled ?? true else { return .none }
        return smartCleanup ?? false ? .medium : .light
    }
}
