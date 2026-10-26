import FluenceCore
import FluenceMeetingCore
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

    /// *Enregistrer sans clic*: seconds after which the *Réunion détectée* card records on its
    /// own. 0, the default, waits for a click (FLU-34, decided in FLU-39: ignoring the card
    /// is not consent). With a delay the card shows it counting down.
    var autoRecordSeconds: Int {
        didSet { defaults.set(autoRecordSeconds, forKey: Keys.autoRecordSeconds) }
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

    /// `.standard`, or the self-test's scratch settings (FLU-35).
    private let defaults = AppPaths.defaults

    private enum Keys {
        static let detectMeetings = "notetaker.detectMeetings"
        static let autoRecordSeconds = "notetaker.autoRecordSeconds"
        /// Before FLU-34: a countdown that recorded after 10 s by default. Dropped, not
        /// carried over, so every install starts from "wait for a click".
        static let oldCountdownSeconds = "notetaker.countdownSeconds"
        static let keepAudioByDefault = "notetaker.keepAudioByDefault"
        static let voicePrintsEnabled = "notetaker.voicePrintsEnabled"
        static let readNamesFromMeetingWindow = "notetaker.readNamesFromMeetingWindow"
        static let useCalendar = "notetaker.useCalendar"
        static let retentionDays = "notetaker.retentionDays"
        static let maxDurationMinutes = "notetaker.maxDurationMinutes"
    }

    private init() {
        detectMeetings = defaults.object(forKey: Keys.detectMeetings) as? Bool ?? true
        defaults.removeObject(forKey: Keys.oldCountdownSeconds)
        // Every number below is read with bounds (R13): an edited or corrupted value falls
        // back to the default instead of recording without a click, deleting meetings or
        // stopping at once.
        autoRecordSeconds = DetectionOffer.storedDelay(defaults.integer(forKey: Keys.autoRecordSeconds))
        keepAudioByDefault = defaults.object(forKey: Keys.keepAudioByDefault) as? Bool ?? false
        voicePrintsEnabled = defaults.object(forKey: Keys.voicePrintsEnabled) as? Bool ?? false
        readNamesFromMeetingWindow = defaults.object(forKey: Keys.readNamesFromMeetingWindow) as? Bool ?? true
        useCalendar = defaults.object(forKey: Keys.useCalendar) as? Bool ?? true
        retentionDays = StoredSettings.meetingRetention(defaults.integer(forKey: Keys.retentionDays))
        maxDurationMinutes = StoredSettings.meetingDuration(defaults.object(forKey: Keys.maxDurationMinutes) as? Int)
    }
}
