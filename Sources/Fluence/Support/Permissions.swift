import AVFoundation
import AppKit
import ApplicationServices
import EventKit
import Foundation

/// Fluence needs two grants, and neither can be worked around:
/// - **Microphone** — obviously.
/// - **Accessibility** — for both the `CGEventTap` (hotkey) and the AX text insert.
///
/// Accessibility has no programmatic request; the OS only shows the prompt, and the user
/// must toggle it in System Settings. TCC also keys on the code signature, so re-signing
/// the app resets the grant.
@MainActor
enum Permissions {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Shows the system Accessibility prompt if the app isn't yet trusted.
    @discardableResult
    static func promptForAccessibility() -> Bool {
        // Spelled out rather than using `kAXTrustedCheckOptionPrompt`, which imports as a
        // mutable global and so isn't usable from concurrency-checked code.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

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

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
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
