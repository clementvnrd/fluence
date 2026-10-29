import Foundation

/// An app that holds calls, identified from the bundle ID of a process using the mic.
public struct MeetingApp: Sendable, Hashable {
    /// What the UI says: "Zoom", "Google Chrome"…
    public var name: String
    /// The app the user sees (and whose windows Accessibility reads). For Safari this is
    /// `com.apple.Safari` even though its audio runs in `com.apple.WebKit.GPU`.
    public var mainBundleID: String
    /// Bundle IDs (or prefixes, see `matches`) of every process of the family — browsers
    /// render audio from helper processes.
    public var bundlePrefixes: [String]
    /// A browser is only a meeting when one of its windows is (checked via window titles).
    public var isBrowser: Bool

    /// Case-insensitive: equal to a prefix, or starts with the prefix followed by a dot
    /// (`com.google.Chrome.helper` belongs to `com.google.Chrome`).
    public func matches(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return bundlePrefixes.contains { prefix in
            let p = prefix.lowercased()
            return id == p || id.hasPrefix(p + ".")
        }
    }
}

public enum MeetingApps {
    public static let native: [MeetingApp] = [
        app("Zoom", "us.zoom.xos", ["us.zoom"]),
        app("Microsoft Teams", "com.microsoft.teams2", ["com.microsoft.teams2", "com.microsoft.teams"]),
        app("Webex", "Cisco-Systems.Spark", ["Cisco-Systems.Spark", "com.webex.meetingmanager", "com.cisco.webexmeetingsapp"]),
        app("Slack", "com.tinyspeck.slackmacgap", ["com.tinyspeck.slackmacgap"]),
        // FaceTime's audio runs in the conferencing daemon, not in the app.
        app("FaceTime", "com.apple.FaceTime", ["com.apple.FaceTime", "com.apple.avconferenced"]),
        app("Discord", "com.hnc.Discord", ["com.hnc.Discord"]),
        app("GoTo Meeting", "com.logmein.GoToMeeting", ["com.logmein.GoToMeeting", "com.logmein.goto"]),
        app("Jitsi Meet", "org.jitsi.jitsi-meet", ["org.jitsi.jitsi-meet"]),
        app("Whereby", "com.whereby.app", ["com.whereby.app"]),
    ]

    public static let browsers: [MeetingApp] = [
        // Chrome PWAs ("Google Meet" installed as an app) are com.google.Chrome.app.<id>.
        browser("Google Chrome", "com.google.Chrome", ["com.google.Chrome"]),
        browser("Arc", "company.thebrowser.Browser", ["company.thebrowser.Browser"]),
        browser("Dia", "company.thebrowser.dia", ["company.thebrowser.dia"]),
        browser("Safari", "com.apple.Safari", ["com.apple.Safari", "com.apple.WebKit"]),
        browser("Microsoft Edge", "com.microsoft.edgemac", ["com.microsoft.edgemac"]),
        browser("Brave", "com.brave.Browser", ["com.brave.Browser"]),
        browser("Firefox", "org.mozilla.firefox", ["org.mozilla.firefox", "org.mozilla.plugincontainer", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]),
        browser("Vivaldi", "com.vivaldi.Vivaldi", ["com.vivaldi.Vivaldi"]),
        browser("Opera", "com.operasoftware.Opera", ["com.operasoftware.Opera"]),
        browser("Helium", "net.imput.helium", ["net.imput.helium"]),
        browser("Comet", "ai.perplexity.comet", ["ai.perplexity.comet"]),
        browser("Zen", "app.zen-browser.zen", ["app.zen-browser.zen"]),
    ]

    /// The meeting app or browser a process belongs to, if any.
    public static func identify(_ bundleID: String) -> MeetingApp? {
        native.first { $0.matches(bundleID) } ?? browsers.first { $0.matches(bundleID) }
    }

    /// The meeting service a browser window title shows, or `nil` when it is not a call.
    /// Conservative on purpose: a false positive only offers a card, but a noisy card gets
    /// turned off.
    public static func meetingService(inWindowTitle title: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        if t.hasPrefix("Meet - ") || t.hasPrefix("Meet – ") || t.hasPrefix("Meet — ")
            || lower.contains("google meet") || lower.contains("meet.google.com") {
            return "Google Meet"
        }
        if lower.contains("microsoft teams") || lower.contains("teams.microsoft.com") || lower.contains("teams.live.com") {
            return "Microsoft Teams"
        }
        if lower.contains("zoom meeting") || lower.contains("zoom workplace") || lower.contains("zoom.us") || lower.hasPrefix("zoom ") {
            return "Zoom"
        }
        if lower.contains("webex") { return "Webex" }
        if lower.contains("whereby") { return "Whereby" }
        if lower.contains("jitsi meet") || lower.contains("meet.jit.si") { return "Jitsi Meet" }
        if lower.contains("huddle") && lower.contains("slack") { return "Slack" }
        return nil
    }

    /// The conferencing service a calendar event's URL, location or notes point to.
    public static func conferencingService(in text: String) -> String? {
        let lower = text.lowercased()
        let patterns: [(String, String)] = [
            ("zoom.us/j/", "Zoom"), ("zoom.us/my/", "Zoom"), ("zoom.us/w/", "Zoom"), ("zoomgov.com/j/", "Zoom"),
            ("teams.microsoft.com/l/meetup-join", "Microsoft Teams"), ("teams.microsoft.com/meet", "Microsoft Teams"),
            ("teams.live.com/meet", "Microsoft Teams"),
            ("meet.google.com/", "Google Meet"),
            ("webex.com/meet", "Webex"), ("webex.com/join", "Webex"), ("webex.com/wbxmjs", "Webex"),
            ("whereby.com/", "Whereby"), ("meet.jit.si/", "Jitsi Meet"),
            ("facetime.apple.com/join", "FaceTime"),
            ("gotomeeting.com/join", "GoTo Meeting"), ("meet.goto.com/", "GoTo Meeting"),
            ("chime.aws/", "Amazon Chime"), ("app.slack.com/huddle", "Slack"),
        ]
        return patterns.first { lower.contains($0.0) }?.1
    }

    private static func app(_ name: String, _ main: String, _ prefixes: [String]) -> MeetingApp {
        MeetingApp(name: name, mainBundleID: main, bundlePrefixes: prefixes, isBrowser: false)
    }

    private static func browser(_ name: String, _ main: String, _ prefixes: [String]) -> MeetingApp {
        MeetingApp(name: name, mainBundleID: main, bundlePrefixes: prefixes, isBrowser: true)
    }
}

/// Cleans display names read from a meeting window's participant list.
public enum ParticipantNames {
    /// Role and self markers Zoom, Teams and Meet append to names (EN and FR).
    static let suffixes = [
        "host", "co-host", "cohost", "me", "you", "guest", "organizer", "organiser", "presenter",
        "hôte", "co-hôte", "moi", "vous", "invité", "invitée", "organisateur", "organisatrice",
        "présentateur", "external", "externe", "unverified", "non vérifié",
    ]

    /// Labels of the controls around a participant list, never names.
    static let controls: Set<String> = [
        "mute", "unmute", "mute all", "participants", "people", "invite", "chat", "raise hand",
        "lower hand", "leave", "more", "search", "close", "rename", "in this meeting",
        "in the meeting", "waiting", "contributors", "everyone", "admit", "remove", "pin",
        "spotlight", "muet", "réactiver le son", "désactiver le son", "inviter", "quitter",
        "plus", "rechercher", "fermer", "lever la main", "dans la réunion", "tout le monde",
    ]

    /// Markers meaning "this row is the user".
    static let selfMarkers: Set<String> = ["me", "you", "moi", "vous"]

    /// Returns cleaned, de-duplicated names in their original order. Strips trailing
    /// parenthesised role markers ("Bob (Guest)"), drops the row the app marks as the user
    /// ("Ada (Host, me)"), control labels, strings that are too short or long, and anything
    /// without a letter. Names matching `excluding` (the user) are removed, case- and
    /// diacritic-insensitively.
    public static func clean(_ raw: [String], excluding user: [String] = []) -> [String] {
        let excluded = Set(user.map(SpeakerNaming.key))
        var seen = Set<String>()
        var result: [String] = []

        for value in raw {
            var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            var isSelf = false
            // Peel off "(…)" groups made only of role markers.
            while name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
                let inner = name[name.index(after: open)..<name.index(before: name.endIndex)]
                let parts = inner.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }
                guard !parts.isEmpty, parts.allSatisfy({ suffixes.contains($0) }) else { break }
                if parts.contains(where: selfMarkers.contains) { isSelf = true }
                name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
            }

            guard !isSelf, name.count >= 2, name.count <= 60,
                  name.contains(where: \.isLetter),
                  !controls.contains(name.lowercased()),
                  !excluded.contains(SpeakerNaming.key(name)),
                  seen.insert(SpeakerNaming.key(name)).inserted
            else { continue }
            result.append(name)
        }
        return result
    }
}

/// Whether the current output route is private to the user's ears, in which case the mic
/// cannot pick up the remote side and echo cancellation is bypassed.
public enum OutputRoute {
    /// Core Audio four-char codes, as `UInt32`.
    public static func fourCC(_ code: String) -> UInt32 {
        code.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// - Parameters:
    ///   - transportType: `kAudioDevicePropertyTransportType` of the default output.
    ///   - dataSource: `kAudioDevicePropertyDataSource` (output scope) when the device has
    ///     one — the built-in output reports `hdpn` for the headphone jack, `ispk` for the
    ///     speakers.
    /// Bluetooth outputs are treated as headphones (AirPods and the like). A Bluetooth
    /// speaker is the known miss; the text dedupe still catches its echo.
    public static func isHeadphones(transportType: UInt32, dataSource: UInt32?) -> Bool {
        switch transportType {
        case fourCC("blue"), fourCC("blea"):
            return true
        case fourCC("bltn"):
            return dataSource == fourCC("hdpn")
        default:
            return false
        }
    }
}
