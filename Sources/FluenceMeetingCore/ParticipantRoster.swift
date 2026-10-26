import Foundation

/// What one walk of the call window's participant panel found (FLU-33). The names are
/// already cleaned (`ParticipantNames.clean`, the user excluded); only their count is ever
/// logged.
public struct ParticipantRead: Sendable, Equatable, Codable {
    public var names: [String]
    /// A participant list was found and read to its end within the walk's budget.
    public var complete: Bool
    /// The number the app prints beside the list's label (« Participants (4) »), which
    /// counts the user too; nil when the label carries none.
    public var reportedCount: Int?

    public init(names: [String], complete: Bool, reportedCount: Int? = nil) {
        self.names = names
        self.complete = complete
        self.reportedCount = reportedCount
    }
}

/// The names read from the call window over a meeting, and whether its list can be
/// trusted to show everyone (FLU-33).
///
/// A walk can stop early (element or time budget), a panel can be scrolled, collapsed or
/// closed, and a web page lays its list out lazily: a list showing one name may hide three
/// more. Capping the voices at such a count merged four people into one, so the window only
/// gives a count when its list looks **complete**:
///
/// - the last two reads were both complete (a list found and read within the budget), and
/// - they show the same people (case- and accent-insensitive), and
/// - when the app prints a count, it matches the names (the names plus the user, or the
///   names alone); when it prints none, they show at least two people — a lone name is
///   too often the one row a partial walk reached.
///
/// Otherwise `trustedCount` is nil and the window gives no cap. `names` keeps every name
/// ever read either way, for naming, whose own rules decide what a name may be given to.
public struct ParticipantRoster: Sendable, Equatable {
    /// Every name read so far, in the order first seen, de-duplicated.
    public private(set) var names: [String] = []
    /// How many walks reported back.
    public private(set) var reads = 0
    private var last: ParticipantRead?
    private var previous: ParticipantRead?

    public init() {}

    public init(reads: [ParticipantRead]) {
        for read in reads { record(read) }
    }

    public mutating func record(_ read: ParticipantRead) {
        reads += 1
        previous = last
        last = read
        names = SpeakerNaming.unique(names + read.names)
    }

    /// The window's list looks like everyone (rules above).
    public var isComplete: Bool {
        guard let last, let previous, last.complete, previous.complete else { return false }
        let now = Set(last.names.map(SpeakerNaming.key))
        guard now == Set(previous.names.map(SpeakerNaming.key)) else { return false }
        if let reported = last.reportedCount {
            return reported == now.count + 1 || reported == now.count
        }
        return now.count >= 2
    }

    /// Remote people the window is trusted to have shown, every read counted; nil when the
    /// list does not look complete.
    public var trustedCount: Int? {
        isComplete ? names.count : nil
    }
}

/// Bounds one walk of another app's accessibility tree: at most `maxElements` elements and
/// `maxDuration` seconds, whichever comes first (FLU-33). Every element read is a round trip
/// that the other app serves on its own main thread, so a long walk makes Chrome or Teams
/// stutter; once the budget is spent the walk stops and says it is incomplete.
public struct WalkBudget {
    /// The participant walk's default: 4,000 elements, 150 ms.
    public static let participantElements = 4_000
    public static let participantDuration: TimeInterval = 0.15

    public let maxElements: Int
    public let maxDuration: TimeInterval
    /// Elements spent so far.
    public private(set) var visited = 0
    /// The budget ran out at least once: whatever the walk returns is partial.
    public private(set) var isExhausted = false
    private let started: TimeInterval
    private let clock: () -> TimeInterval

    public init(
        maxElements: Int = WalkBudget.participantElements,
        maxDuration: TimeInterval = WalkBudget.participantDuration,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.maxElements = maxElements
        self.maxDuration = maxDuration
        self.clock = clock
        started = clock()
    }

    /// Spends one element. False — and exhausted from then on — once either bound is
    /// reached.
    public mutating func spend() -> Bool {
        guard !isExhausted else { return false }
        if visited >= maxElements || clock() - started >= maxDuration {
            isExhausted = true
            return false
        }
        visited += 1
        return true
    }

    /// Seconds left, never negative.
    public var remaining: TimeInterval {
        max(0, maxDuration - (clock() - started))
    }
}

extension ParticipantNames {
    /// Labels of a participant list container (Zoom's window title, Teams' and Meet's
    /// panels), lowercased.
    static let listLabels = [
        "participants", "people", "in this meeting", "in the meeting", "attendees",
        "personnes", "dans la réunion", "participants à la réunion",
    ]

    /// Whether an element's title or description names a participant list: a known label,
    /// alone or followed by its count (« Participants (4) », « People · 3 »).
    public static func isListLabel(_ label: String) -> Bool {
        let lower = label.lowercased().trimmingCharacters(in: .whitespaces)
        return listLabels.contains { lower == $0 || lower.hasPrefix($0 + " (") || lower.hasPrefix($0 + " ·") }
    }

    /// The count printed in a list label, the user included: « Participants (4) » → 4,
    /// « People · 3 » → 3. Nil without one, or when it is not a plain number.
    public static func reportedCount(inLabel label: String) -> Int? {
        let lower = label.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in listLabels.sorted(by: { $0.count > $1.count }) {
            if lower.hasPrefix(prefix + " (") {
                let rest = lower.dropFirst(prefix.count + 2)
                guard let close = rest.firstIndex(of: ")") else { return nil }
                return Int(rest[..<close].trimmingCharacters(in: .whitespaces))
            }
            if lower.hasPrefix(prefix + " ·") {
                let digits = lower.dropFirst(prefix.count + 2).trimmingCharacters(in: .whitespaces)
                    .prefix(while: \.isNumber)
                return digits.isEmpty ? nil : Int(digits)
            }
        }
        return nil
    }
}
