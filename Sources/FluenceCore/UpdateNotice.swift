import Foundation

// FLU-80: telling the user an update is ready while Fluence lives in the menu bar — one
// macOS notification per version, an « Installer Fluence x.y.z » item at the top of the menu
// bar menu and a blue dot on its icon. The rules live here; `AppUpdater` only applies them.

/// What is recording right now, as far as updates are concerned. A meeting wins over a
/// dictation: it is the longer of the two, so « À la fin de la réunion » is the truer wait.
public enum UpdateRecording: Equatable, Sendable {
    case none
    case dictation
    case meeting

    public static func from(dictating: Bool, meetingInProgress: Bool) -> Self {
        if meetingInProgress { return .meeting }
        return dictating ? .dictation : .none
    }

    /// Same rule as `UpdatePolicy.isBusy`.
    public var isBusy: Bool { self != .none }
}

/// The item at the top of the menu bar menu.
public enum UpdateMenuItem: Equatable, Sendable {
    /// No version waiting, or no updater in this build.
    case hidden
    /// « Installer Fluence x.y.z »: one click installs and relaunches.
    case ready(version: String)
    /// Greyed out, « À la fin de la réunion » under it.
    case waitingForMeeting(version: String)
    /// Greyed out, « À la fin de la dictée » under it.
    case waitingForDictation(version: String)

    public static func resolve(updaterRunning: Bool, readyVersion: String?, recording: UpdateRecording) -> Self {
        guard updaterRunning, let version = readyVersion, !version.isEmpty else { return .hidden }
        switch recording {
        case .none: return .ready(version: version)
        case .dictation: return .waitingForDictation(version: version)
        case .meeting: return .waitingForMeeting(version: version)
        }
    }

    /// « Rechercher des mises à jour… » at the bottom of the menu: only while the top item
    /// is hidden in a build that has an updater, so the menu never offers both.
    public static func showsCheckForUpdates(updaterRunning: Bool, readyVersion: String?) -> Bool {
        updaterRunning && resolve(updaterRunning: true, readyVersion: readyVersion, recording: .none) == .hidden
    }

    public var isVisible: Bool { self != .hidden }

    /// Clickable only when nothing records: never install in the middle of a recording.
    public var isEnabled: Bool {
        if case .ready = self { return true }
        return false
    }

    /// No « … »: the click installs, there is nothing else to confirm.
    public var title: String? {
        switch self {
        case .hidden: nil
        case .ready(let version), .waitingForMeeting(let version), .waitingForDictation(let version):
            "Installer Fluence \(version)"
        }
    }

    public var subtitle: String? {
        switch self {
        case .hidden, .ready: nil
        case .waitingForMeeting: "À la fin de la réunion"
        case .waitingForDictation: "À la fin de la dictée"
        }
    }

    /// The blue dot on the menu bar icon: whenever a version waits, recording or not.
    public static func showsDot(updaterRunning: Bool, readyVersion: String?) -> Bool {
        resolve(updaterRunning: updaterRunning, readyVersion: readyVersion, recording: .none) != .hidden
    }
}

/// The macOS notification « Fluence x.y.z est prête ».
public enum UpdateNotificationPolicy {
    public static let identifier = "update-ready"
    public static let category = "update"
    public static let installAction = "install"

    public static func title(version: String) -> String { "Fluence \(version) est prête" }
    public static let body = "Installer prend quelques secondes."
    public static let installTitle = "Installer"

    /// UserDefaults key holding the last version a notification went out for. A version
    /// number, nothing personal.
    public static let notifiedVersionKey = "updateNotifiedVersion"

    /// Post now? Once per version, only while Fluence is in the background — in front, the
    /// question « Fluence x.y.z est disponible » does the job — never once that question has
    /// been asked, and never during a recording: `AppUpdater` asks again when it ends.
    public static func shouldPost(
        readyVersion: String?,
        notifiedVersion: String?,
        alreadyAsked: Bool,
        appIsActive: Bool,
        isBusy: Bool
    ) -> Bool {
        guard let version = readyVersion, !version.isEmpty else { return false }
        guard version != notifiedVersion, !alreadyAsked else { return false }
        return !appIsActive && !isBusy
    }

    /// A click on the banner opens Fluence and asks « Fluence x.y.z est disponible ». The
    /// activation that click causes may already have asked (the order of the two events is
    /// the system's): ask again only when no answer came in the last few seconds, so the
    /// same question is never shown twice in a row.
    public static func bannerClickAsksAgain(lastAnswer: Date?, now: Date, window: TimeInterval = 3) -> Bool {
        guard let lastAnswer else { return true }
        return now.timeIntervalSince(lastAnswer) > window
    }
}
