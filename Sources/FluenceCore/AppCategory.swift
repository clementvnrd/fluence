import Foundation

/// The kind of place a dictation is going, which decides its writing style at level High.
/// Wispr Flow's four categories.
public enum AppCategory: String, CaseIterable, Sendable, Codable {
    case personal
    case work
    case email
    case other

    public var displayName: String {
        switch self {
        case .personal: "Messages personnels"
        case .work: "Messages pro"
        case .email: "E-mail"
        case .other: "Autres"
        }
    }

    /// Casual among friends and family; formal everywhere a colleague or a stranger reads.
    public var defaultStyle: WritingStyle { self == .personal ? .casual : .formal }

    /// Classifies the frontmost app, and — for a browser — the page in its front tab.
    ///
    /// - Parameters:
    ///   - bundleID: the frontmost application's bundle identifier.
    ///   - url: the front tab's address when the app is a browser and it could be read.
    ///     Only its host is looked at, and nothing here keeps or logs it.
    public static func classify(bundleID: String?, url: String?) -> AppCategory {
        guard let bundleID = bundleID?.lowercased() else { return .other }
        if let category = apps[bundleID] { return category }
        guard isBrowser(bundleID: bundleID), let url, let host = host(of: url) else { return .other }
        return classify(host: host)
    }

    /// Whether the front tab's address is worth reading for this app. Nothing else's is.
    public static func isBrowser(bundleID: String) -> Bool {
        let bundleID = bundleID.lowercased()
        // Web apps wrapped as standalone apps by Chrome/Edge/Safari ("Add to Dock") carry a
        // generated bundle ID; their URL, when readable, still classifies them.
        return browsers.contains(bundleID)
            || bundleID.hasPrefix("com.google.chrome.app.")
            || bundleID.hasPrefix("com.apple.safari.webapp")
    }

    /// The category of a web page from its host name.
    public static func classify(host: String) -> AppCategory {
        let host = host.lowercased()
        for (suffix, category) in sites where host == suffix || host.hasSuffix("." + suffix) {
            return category
        }
        return .other
    }

    /// The host of an address, tolerating one typed without a scheme.
    static func host(of url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let host = URLComponents(string: trimmed)?.host, !host.isEmpty { return host }
        return URLComponents(string: "https://" + trimmed)?.host
    }

    // MARK: - Tables

    /// Native apps. Lowercased bundle IDs.
    static let apps: [String: AppCategory] = [
        // Personal
        "com.apple.mobilesms": .personal,           // Messages
        "net.whatsapp.whatsapp": .personal,
        "desktop.whatsapp": .personal,
        "ru.keepcoder.telegram": .personal,         // Telegram (App Store)
        "org.telegram.desktop": .personal,
        "org.whispersystems.signal-desktop": .personal,
        "com.hnc.discord": .personal,
        "com.facebook.archon": .personal,           // Messenger
        "com.facebook.archon.developerid": .personal,
        // Work
        "com.tinyspeck.slackmacgap": .work,         // Slack
        "com.microsoft.teams": .work,
        "com.microsoft.teams2": .work,
        "com.webex.meetingmanager": .work,
        "us.zoom.xos": .work,                       // Zoom's team chat
        "com.google.chat": .work,
        "com.mattermost.desktop": .work,
        // Email
        "com.apple.mail": .email,
        "com.microsoft.outlook": .email,
        "com.readdle.smartemail-mac": .email,       // Spark (classic)
        "com.readdle.spark": .email,                // Spark (2024+)
        "com.superhuman.electron": .email,
        "com.airmailapp.airmail5": .email,
        "com.mimestream.mimestream": .email,
        "com.freron.mailmate": .email,
        "it.bloop.airmail2": .email,
        "com.canarymail.mac": .email,
        "org.mozilla.thunderbird": .email,
        "com.hey.app.desktop": .email,
    ]

    /// Browsers whose front tab decides. Lowercased bundle IDs.
    static let browsers: Set<String> = [
        "com.apple.safari", "com.apple.safaritechnologypreview",
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev", "com.google.chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.dev",
        "com.brave.browser", "com.brave.browser.beta", "company.thebrowser.browser", // Arc
        "company.thebrowser.dia", "com.vivaldi.vivaldi", "com.operasoftware.opera",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen",
        "org.chromium.chromium", "com.kagi.kagimacos",                               // Orion
    ]

    /// Web apps, by host suffix. The first match wins, so more specific hosts come first.
    static let sites: [(String, AppCategory)] = [
        ("mail.google.com", .email),
        ("gmail.com", .email),
        ("outlook.live.com", .email),
        ("outlook.office.com", .email),
        ("outlook.office365.com", .email),
        ("mail.yahoo.com", .email),
        ("mail.proton.me", .email),
        ("app.fastmail.com", .email),
        ("app.superhuman.com", .email),
        ("app.hey.com", .email),
        ("teams.microsoft.com", .work),
        ("teams.live.com", .work),
        ("slack.com", .work),
        ("chat.google.com", .work),
        ("web.whatsapp.com", .personal),
        ("messenger.com", .personal),
        ("web.telegram.org", .personal),
        ("discord.com", .personal),
        ("instagram.com", .personal),
    ]
}

/// How a dictation reads at level High. Wispr Flow's styles.
public enum WritingStyle: String, CaseIterable, Sendable, Codable {
    case formal
    case casual
    case veryCasual

    public var displayName: String {
        switch self {
        case .formal: "Soutenu"
        case .casual: "Décontracté"
        case .veryCasual: "Très décontracté"
        }
    }

    /// One line describing the style, shown under the picker.
    public var example: String {
        switch self {
        case .formal: "Full sentences, capitals and punctuation, no slang."
        case .casual: "Natural and relaxed, contractions welcome, still properly punctuated."
        case .veryCasual: "Lowercase, light punctuation, like a quick text."
        }
    }
}
