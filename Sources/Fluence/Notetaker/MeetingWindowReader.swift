import AppKit
import ApplicationServices
import Foundation

/// Reads meeting apps' windows through Accessibility, which Fluence already holds for
/// dictation — never `CGWindowList`, which would need Screen Recording.
///
/// Two uses:
/// - **Window titles**, to tell a browser on a call ("Meet – abc-defg-hij") from a browser
///   that merely has the mic open.
/// - **Participant names**, best effort: Zoom, Teams and Meet expose their participant
///   panel as AX lists, but none of them documents its AX tree and each update can change
///   it. The reader looks for a container labelled like a participant list and collects
///   the text under it; `ParticipantNames.clean` removes role markers and control labels.
///   When the panel is closed nothing is found, and naming falls back to the calendar. A
///   read says whether it saw the whole list (FLU-33), and only a list that looks complete
///   caps the voices (`ParticipantRoster`).
///
/// Each AX read is a round trip served by the other app's main thread. The participant
/// walk runs on its own serial queue, never on Fluence's main thread, within a budget of
/// 4,000 elements and 150 ms (`WalkBudget`), each call bounded by what is left of it.
///
/// Nothing read here is logged.
@MainActor
enum MeetingWindowReader {
    /// Titles of the app's windows (for a browser: the front tab of each window).
    static func windowTitles(pid: pid_t) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        return elements(app, kAXWindowsAttribute).compactMap { string($0, kAXTitleAttribute) }
    }

    /// The first meeting service any of the app's window titles shows.
    static func meetingService(pid: pid_t) -> String? {
        windowTitles(pid: pid).lazy.compactMap(MeetingApps.meetingService(inWindowTitle:)).first
    }

    /// The pid of the app the user sees for a meeting app family (Safari for WebKit
    /// helpers, Chrome for its helpers).
    static func mainPID(for app: MeetingApp) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.mainBundleID).first?.processIdentifier
            ?? NSWorkspace.shared.runningApplications.first { running in
                running.bundleIdentifier.map(app.matches) ?? false
            }?.processIdentifier
    }

    // MARK: - Participants

    /// One read of a visible participant panel (FLU-33), on `walkQueue`: the main thread
    /// only awaits it. The caller skips a walk while one is still running.
    nonisolated static func participants(pid: pid_t, excluding user: [String]) async -> ParticipantRead {
        await withCheckedContinuation { continuation in
            walkQueue.async {
                continuation.resume(returning: walkParticipants(pid: pid, excluding: user, budget: WalkBudget()))
            }
        }
    }

    /// One walk at a time, at utility priority, beside everything Fluence's main thread does.
    private nonisolated static let walkQueue = DispatchQueue(label: "io.github.clementvnrd.fluence.participant-walk", qos: .utility)

    /// The walk itself, on the calling thread: the cleaned names, whether the list was found
    /// and read to its end within `budget` (elements and time), and the count the app prints
    /// beside it. It stops at the first list it reads.
    private nonisolated static func walkParticipants(pid: pid_t, excluding user: [String], budget: WalkBudget) -> ParticipantRead {
        guard AXIsProcessTrusted() else { return ParticipantRead(names: [], complete: false) }
        var budget = budget
        let app = AXUIElementCreateApplication(pid)
        bound(app, by: budget)
        let windows = elements(app, kAXWindowsAttribute)

        func read(_ list: AXUIElement, label: String) -> ParticipantRead {
            let raw = texts(under: list, budget: &budget)
            return ParticipantRead(
                names: ParticipantNames.clean(raw, excluding: user),
                complete: !budget.isExhausted,
                reportedCount: ParticipantNames.reportedCount(inLabel: label)
            )
        }

        // Zoom shows participants in their own window, « Participants (4) ».
        for window in windows {
            bound(window, by: budget)
            if let title = string(window, kAXTitleAttribute), ParticipantNames.isListLabel(title) {
                return read(window, label: title)
            }
        }
        var queue: [(AXUIElement, Int)] = windows.map { ($0, 0) }
        var next = 0
        while next < queue.count, budget.spend() {
            let (element, depth) = queue[next]
            next += 1
            bound(element, by: budget)
            let label = string(element, kAXDescriptionAttribute) ?? string(element, kAXTitleAttribute) ?? ""
            let role = string(element, kAXRoleAttribute) ?? ""
            if ParticipantNames.isListLabel(label), ["AXList", "AXOutline", "AXTable", "AXGroup"].contains(role) {
                return read(element, label: label)
            }
            guard depth < 30 else { continue }
            queue += elements(element, kAXChildrenAttribute).map { ($0, depth + 1) }
        }
        return ParticipantRead(names: [], complete: false)
    }

    /// Static texts and row descriptions under `root`.
    private nonisolated static func texts(under root: AXUIElement, budget: inout WalkBudget) -> [String] {
        var result: [String] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (element, depth) = stack.popLast() {
            guard budget.spend() else { break }
            bound(element, by: budget)
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == kAXStaticTextRole as String, let value = string(element, kAXValueAttribute) {
                result.append(value)
            } else if role == "AXRow" || role == "AXCell" || role == "AXListItem",
                      let description = string(element, kAXDescriptionAttribute) {
                result.append(description)
            }
            if depth < 12 {
                stack += elements(element, kAXChildrenAttribute).reversed().map { ($0, depth + 1) }
            }
        }
        return result
    }

    // MARK: - AX helpers

    /// A busy app answers each AX call late, by default after up to 6 s: never wait longer
    /// than what is left of the walk's budget (at least 20 ms). Local to this element ref.
    private nonisolated static func bound(_ element: AXUIElement, by budget: WalkBudget) {
        AXUIElementSetMessagingTimeout(element, Float(max(0.02, budget.remaining)))
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        // swiftlint:disable:next force_cast
        return (value as! [AnyObject]).compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }
}
