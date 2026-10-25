import Foundation

/// Values read back from the defaults, checked before anything uses them (R13, audit
/// 2026-10-08).
///
/// The defaults are a file anyone can edit (`defaults write`, a sync tool, a downgrade that
/// stored something else under the key). A value the app would never have written must not
/// crash every launch — `UInt32(-1)` and `Int.max * 60` both trap — so each reader below
/// returns the default for anything out of range rather than trusting it.
public enum StoredSettings {
    // MARK: - Dictation

    /// Minutes before a dictation is finished on its own. The default when unset or absurd.
    public static let defaultRecordingLimit = 10
    public static let recordingLimitRange = 1...120

    public static func recordingLimit(_ stored: Int) -> Int {
        recordingLimitRange.contains(stored) ? stored : defaultRecordingLimit
    }

    // MARK: - Meetings

    /// Minutes before a meeting recording stops on its own.
    public static let defaultMeetingDuration = 180
    public static let meetingDurationRange = 1...(24 * 60)

    public static func meetingDuration(_ stored: Int?) -> Int {
        guard let stored, meetingDurationRange.contains(stored) else { return defaultMeetingDuration }
        return stored
    }

    /// Days meetings are kept; `nil` keeps them. A value past ten years (or not positive) is
    /// read as « keep »: a corrupted value must never be what deletes meetings.
    public static let meetingRetentionRange = 1...3_650

    public static func meetingRetention(_ stored: Int) -> Int? {
        meetingRetentionRange.contains(stored) ? stored : nil
    }
}

/// A shortcut recorded in Settings, stored as
/// `combo:<keyCode>:<modifierFlags>:<isModifierOnly>:<shortName>:<displayName>`.
///
/// Parsed here, bounds included, so a hand-edited or corrupted value is refused instead of
/// reaching `UInt32(keyCode)` in the hotkey monitor, which traps on a negative or huge code.
public struct ShortcutCombo: Equatable, Sendable {
    /// A macOS virtual key code (`CGKeyCode` is 16 bits).
    public let keyCode: UInt16
    public let modifierFlags: UInt64
    public let isModifierOnly: Bool
    public let shortName: String
    public let displayName: String

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 6, parts[0] == "combo",
              let keyCode = UInt16(parts[1]),
              let modifierFlags = UInt64(parts[2]),
              let isModifierOnly = Bool(String(parts[3]))
        else { return nil }
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.isModifierOnly = isModifierOnly
        shortName = String(parts[4])
        displayName = String(parts[5])
    }
}
