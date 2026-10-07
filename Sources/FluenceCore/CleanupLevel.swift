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
    /// Light, then the on-device model: self-corrections, lists, numbers.
    case medium
    /// Medium, plus a rewrite in the style chosen for the kind of app being typed into.
    case high

    /// Whether this level runs the Foundation Models pass at all.
    public var usesModel: Bool { self == .medium || self == .high }

    /// Whether this level applies the per-app-category writing style.
    public var appliesStyle: Bool { self == .high }

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
