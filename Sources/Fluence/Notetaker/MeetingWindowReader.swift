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
///   When the panel is closed nothing is found, and naming falls back to the calendar.
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

    private static let listLabels = [
        "participants", "people", "in this meeting", "in the meeting", "attendees",
        "personnes", "dans la réunion", "participants à la réunion",
    ]

    /// Raw candidate names from a visible participant panel. Bounded walk: at most
    /// `budget` elements, so a huge web page cannot stall the main thread.
    static func participantCandidates(pid: pid_t, budget: Int = 4_000) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var visited = 0
        var names: [String] = []

        for window in elements(app, kAXWindowsAttribute) {
            // Zoom shows participants in their own window, "Participants (4)".
            if let title = string(window, kAXTitleAttribute), isListLabel(title) {
                names += texts(under: window, visited: &visited, budget: budget)
                continue
            }
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            while !queue.isEmpty, visited < budget {
                let (element, depth) = queue.removeFirst()
                visited += 1
                let label = string(element, kAXDescriptionAttribute) ?? string(element, kAXTitleAttribute) ?? ""
                let role = string(element, kAXRoleAttribute) ?? ""
                if isListLabel(label), ["AXList", "AXOutline", "AXTable", "AXGroup"].contains(role) {
                    names += texts(under: element, visited: &visited, budget: budget)
                    continue
                }
                guard depth < 30 else { continue }
                queue += elements(element, kAXChildrenAttribute).map { ($0, depth + 1) }
            }
        }
        return names
    }

    private static func isListLabel(_ label: String) -> Bool {
        let lower = label.lowercased().trimmingCharacters(in: .whitespaces)
        return listLabels.contains { lower == $0 || lower.hasPrefix($0 + " (") || lower.hasPrefix($0 + " ·") }
    }

    /// Static texts and row descriptions under `root`.
    private static func texts(under root: AXUIElement, visited: inout Int, budget: Int) -> [String] {
        var result: [String] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (element, depth) = stack.popLast(), visited < budget {
            visited += 1
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

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        // swiftlint:disable:next force_cast
        return (value as! [AnyObject]).compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }
}
