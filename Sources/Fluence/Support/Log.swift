import OSLog

enum Log {
    /// The bundle identifier, so the subsystem follows the app's identity rather than a
    /// literal that silently goes stale on a rename. `log show --predicate 'subsystem ==
    /// "uk.co.delff.fluence"'`.
    private static let subsystem = Bundle.main.bundleIdentifier ?? "fluence"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let inject = Logger(subsystem: subsystem, category: "inject")
    static let app = Logger(subsystem: subsystem, category: "app")
}
