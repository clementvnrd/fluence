import AVFoundation
import AppKit
import ApplicationServices
import EventKit
import Foundation

/// Fluence needs two grants, and neither can be worked around:
/// the microphone, and Accessibility (the shortcut event tap, and typing through AX).
///
/// For Accessibility the app can only raise the system prompt; the switch itself is the
/// user's, in System Settings. TCC remembers it by code signature, so a re-signed build has to
/// be granted again.
@MainActor
enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Only an explicit grant counts: denied, restricted and never asked all read false.
    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Whether the app is trusted; when it isn't, macOS puts up its prompt as well.
    @discardableResult
    static func promptForAccessibility() -> Bool {
        // A literal key: Swift 6 refuses `kAXTrustedCheckOptionPrompt`, a mutable C global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Asks for the microphone only the first time; after a refusal only Settings can change it.
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Opens one privacy pane of System Settings.
    private static func openPane(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openAccessibilitySettings() {
        openPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        openPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Resets the TCC accessibility entry for this app when macOS permission gets wedged across rebuilds.
    ///
    /// Only this app's row: the bundle ID is always passed, because a bare
    /// `tccutil reset Accessibility` wipes every app on the machine (see AGENTS.md).
    static func resetAccessibilityTCC() {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return }
        let task = Process()
        task.launchPath = "/usr/bin/tccutil"
        task.arguments = ["reset", "Accessibility", bundleID]
        try? task.run()
        task.waitUntilExit()

        let kill = Process()
        kill.launchPath = "/usr/bin/killall"
        kill.arguments = ["System Settings"]
        try? kill.run()
        kill.waitUntilExit()

        openAccessibilitySettings()
    }
}

// MARK: FLU-5 input — what the onboarding window needs beyond the two hard requirements.

extension Permissions {
    static var microphoneUndecided: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    /// Calendar is optional: meeting notes use it for titles and attendee names.
    static var hasCalendar: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static var calendarUndecided: Bool {
        EKEventStore.authorizationStatus(for: .event) == .notDetermined
    }

    /// Asked only from a button the user pressed, never at launch.
    static func requestCalendar() async -> Bool {
        do {
            return try await EKEventStore().requestFullAccessToEvents()
        } catch {
            Log.app.error("calendar access request failed: \(error.localizedDescription, privacy: .public)")
            Diagnostics.error("permission.calendar.request", error)
            return false
        }
    }

    /// System Audio Recording has no public status query: macOS asks the first time the
    /// meeting tap starts. The pane is still where a refusal is undone.
    static func openSystemAudioSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }

    static func openCalendarSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }
}
