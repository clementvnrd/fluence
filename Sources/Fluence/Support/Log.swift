import OSLog

enum Log {
    /// The bundle identifier, so the subsystem follows the app's identity rather than a
    /// literal that silently goes stale on a rename. `log show --predicate 'subsystem ==
    /// "io.github.clementvnrd.fluence"'`.
    private static let subsystem = Bundle.main.bundleIdentifier ?? "fluence"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let inject = Logger(subsystem: subsystem, category: "inject")
    static let app = Logger(subsystem: subsystem, category: "app")
    /// One line per dictation with its timings and the running medians (FLU-31). Numbers only.
    /// `log show --last 1d --predicate 'category == "latency"'`.
    static let latency = Logger(subsystem: subsystem, category: "latency")

    /// FLU-31: one interval per dictation from key-up to the text, with events at the
    /// microphone's close and the engine's result. In Instruments' Points of Interest track,
    /// or `log stream --signpost --predicate 'subsystem == "…"'`. Numbers only, never text.
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}
