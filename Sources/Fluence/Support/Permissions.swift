import AVFoundation
import AppKit
import ApplicationServices
import EventKit
import FluenceCore
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

    /// FLU-37: set the first time Fluence is seen trusted, cleared only by « Réparer ». Untrusted
    /// with it set is the wedge: the switch still shows on in System Settings, but macOS kept the
    /// requirement of an earlier signature and no longer applies it.
    private static let trustedOnceKey = "accessibilityTrustedOnce"

    /// Whether macOS applies the Accessibility grant, telling a wedge from a grant never given.
    /// Every read keeps the « trusted once » flag up to date.
    static var accessibilityState: AccessibilityGrant.State {
        let trusted = AXIsProcessTrusted()
        let defaults = AppPaths.defaults
        let stored = defaults.bool(forKey: trustedOnceKey)
        let remembers = AccessibilityGrant.remembersTrust(isTrusted: trusted, stored: stored)
        if remembers != stored { defaults.set(remembers, forKey: trustedOnceKey) }
        return AccessibilityGrant.state(isTrusted: trusted, wasTrustedBefore: stored)
    }

    /// Only an explicit grant counts: denied, restricted and never asked all read false.
    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Whether the app is trusted; when it isn't, macOS puts up its prompt as well.
    @discardableResult
    static func promptForAccessibility() -> Bool {
        accessibilityPromptShown = true
        // A literal key: Swift 6 refuses `kAXTrustedCheckOptionPrompt`, a mutable C global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// FLU-37: macOS's prompt was raised in this run (by « Autoriser » or « Réparer »).
    private(set) static var accessibilityPromptShown = false

    /// « Autoriser l'Accessibilité » opens one thing at a time: macOS's prompt, then — once it
    /// has been shown — System Settings. Both at once put a system alert over the pane.
    static func requestAccessibility() {
        switch AccessibilityGrant.nextRequest(promptShown: accessibilityPromptShown) {
        case .systemPrompt: promptForAccessibility()
        case .openSettings: openAccessibilitySettings()
        }
    }

    static var accessibilityRequestTitle: String {
        AccessibilityGrant.requestTitle(promptShown: accessibilityPromptShown)
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

    /// Réglages Système › Son, where the input device is chosen (FLU-29: « Micro
    /// indisponible » when the capture could not start).
    static func openSoundInputSettings() {
        openPane("x-apple.systempreferences:com.apple.Sound-Settings.extension?input")
    }

    /// « Réparer » (FLU-37), run only from a button the user clicked: removes this app's
    /// Accessibility row, then asks again, so Fluence is back in the list for the user to switch
    /// on — the old « Réinitialiser » left it gone from the list.
    ///
    /// Only this app's row: the bundle ID is always passed (`AccessibilityGrant.resetArguments`
    /// refuses to build the command without one), because a bare `tccutil reset Accessibility`
    /// wipes every app on the machine (see AGENTS.md).
    static func repairAccessibility() async {
        guard let arguments = AccessibilityGrant.resetArguments(bundleID: Bundle.main.bundleIdentifier) else {
            Log.app.error("accessibility repair skipped: no usable bundle identifier")
            Diagnostics.error("permission.accessibility.repair.bundleID")
            return
        }
        let status = await run("/usr/bin/tccutil", arguments)
        if status != 0 {
            Log.app.error("accessibility reset failed: tccutil exit \(status, privacy: .public)")
            Diagnostics.error("permission.accessibility.reset", code: Int(status))
        } else {
            Log.app.info("accessibility row reset for this app")
        }
        // The next page asks for the grant instead of showing the wedge again.
        AppPaths.defaults.set(AccessibilityGrant.afterRepair, forKey: trustedOnceKey)
        // System Settings caches the Privacy list: quit it, so the row it shows next is fresh.
        _ = await run("/usr/bin/killall", ["System Settings"])
        // Puts Fluence back in the list, switch off, and raises macOS's own prompt.
        promptForAccessibility()
    }

    /// Runs a system tool off the main thread and returns its exit status (-1 if it could not
    /// start). Its output is not read: neither tool prints anything Fluence needs.
    private static func run(_ path: String, _ arguments: [String]) async -> Int32 {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return Int32(-1)
            }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
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
