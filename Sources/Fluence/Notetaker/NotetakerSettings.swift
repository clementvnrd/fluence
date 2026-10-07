import Foundation
import Observation

/// Notetaker preferences. Separate from `Settings` so the dictation and meeting features
/// can evolve without touching each other's storage.
@MainActor
@Observable
final class NotetakerSettings {
    static let shared = NotetakerSettings()

    /// Watch for calls (mic in use by a meeting app) and offer to take notes.
    var detectMeetings: Bool {
        didSet { defaults.set(detectMeetings, forKey: Keys.detectMeetings) }
    }

    /// Seconds the *Meeting detected* card counts down before recording. 0 = never start
    /// on its own; the user must click. Recording never starts silently either way.
    var countdownSeconds: Int {
        didSet { defaults.set(countdownSeconds, forKey: Keys.countdownSeconds) }
    }

    /// Decision FLU-9 #2: off by default. Per meeting, the user can still keep the audio.
    var keepAudioByDefault: Bool {
        didSet { defaults.set(keepAudioByDefault, forKey: Keys.keepAudioByDefault) }
    }

    /// Decision FLU-9 #3: voice prints are biometric data (GDPR art. 9) — opt-in, off by
    /// default. Turning this off deletes every enrolled print.
    var voicePrintsEnabled: Bool {
        didSet { defaults.set(voicePrintsEnabled, forKey: Keys.voicePrintsEnabled) }
    }

    /// Read display names from the Zoom / Teams / Meet window through Accessibility.
    var readNamesFromMeetingWindow: Bool {
        didSet { defaults.set(readNamesFromMeetingWindow, forKey: Keys.readNamesFromMeetingWindow) }
    }

    /// Use calendar events for the meeting title and attendee names.
    var useCalendar: Bool {
        didSet { defaults.set(useCalendar, forKey: Keys.useCalendar) }
    }

    /// Delete meetings older than this many days. `nil` keeps them.
    var retentionDays: Int? {
        didSet { defaults.set(retentionDays ?? 0, forKey: Keys.retentionDays) }
    }

    /// Stop on its own after this long, whatever happens.
    var maxDurationMinutes: Int {
        didSet { defaults.set(maxDurationMinutes, forKey: Keys.maxDurationMinutes) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let detectMeetings = "notetaker.detectMeetings"
        static let countdownSeconds = "notetaker.countdownSeconds"
        static let keepAudioByDefault = "notetaker.keepAudioByDefault"
        static let voicePrintsEnabled = "notetaker.voicePrintsEnabled"
        static let readNamesFromMeetingWindow = "notetaker.readNamesFromMeetingWindow"
        static let useCalendar = "notetaker.useCalendar"
        static let retentionDays = "notetaker.retentionDays"
        static let maxDurationMinutes = "notetaker.maxDurationMinutes"
    }

    private init() {
        detectMeetings = defaults.object(forKey: Keys.detectMeetings) as? Bool ?? true
        countdownSeconds = defaults.object(forKey: Keys.countdownSeconds) as? Int ?? 10
        keepAudioByDefault = defaults.object(forKey: Keys.keepAudioByDefault) as? Bool ?? false
        voicePrintsEnabled = defaults.object(forKey: Keys.voicePrintsEnabled) as? Bool ?? false
        readNamesFromMeetingWindow = defaults.object(forKey: Keys.readNamesFromMeetingWindow) as? Bool ?? true
        useCalendar = defaults.object(forKey: Keys.useCalendar) as? Bool ?? true
        let days = defaults.integer(forKey: Keys.retentionDays)
        retentionDays = days > 0 ? days : nil
        maxDurationMinutes = defaults.object(forKey: Keys.maxDurationMinutes) as? Int ?? 180
    }
}
