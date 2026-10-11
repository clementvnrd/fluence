import AppKit
import FluenceCore
import SwiftUI

/// Dock icon or menu bar only (FLU-59).
///
/// One process, two presences. With a window open Fluence is a regular app (Dock icon, app
/// menu). Close the last window and it goes to the background (`.accessory`): the icon leaves
/// the Dock, and dictation, the shortcuts, the HUD and meeting detection keep running behind the
/// menu bar icon, whose first item brings the window back. None of those depends on the
/// activation policy; it only decides whether the app shows up in the Dock and ⌘-Tab.
///
/// Anything that opens a window from the background must call `becomeRegular()` first: a
/// background app cannot bring Settings to the front, and a window with no Dock icon is easy to
/// lose.
@MainActor
final class AppPresence {
    static let shared = AppPresence()

    private var closeObserver: NSObjectProtocol?

    /// macOS opens a login item with an open-application event that says so (`lgit`).
    /// Read it while the app finishes launching: afterwards the event is gone.
    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication),
              let how = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))
        else { return false }
        return how.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// Whether this launch opens in the menu bar only: at login, or — development only, under a
    /// scratch folder like the other hooks — with `FLUENCE_START_IN_BACKGROUND=1`, which stands in
    /// for a login that cannot be triggered from a script.
    static var startsInBackground: Bool {
        if launchedAtLogin { return true }
        return AppPaths.override != nil
            && ProcessInfo.processInfo.environment["FLUENCE_START_IN_BACKGROUND"] == "1"
    }

    /// Called once at launch. `inBackground`: a start at login opens no window and no Dock icon.
    func start(inBackground: Bool) {
        NSApp.setActivationPolicy(inBackground ? .accessory : .regular)
        if inBackground { hideMainWindowOnceCreated() }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Delivered on the main queue; hopped to the main actor rather than asserted (see
            // AGENTS.md on `MainActor.assumeIsolated`). The window is only inspected there.
            let window = note.object as? NSWindow
            Task { @MainActor in self?.windowClosed(window) }
        }
    }

    /// Puts the Dock icon back. Idempotent; call it before opening any window.
    func becomeRegular() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    /// « Ouvrir Fluence »: the Dock icon, then the main window in front.
    func showMainWindow(openWindow: OpenWindowAction) {
        becomeRegular()
        if let window = Self.mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The reopen event (Dock icon, Finder, Spotlight, a second copy handing over) when no window
    /// is up: same as the menu item.
    func reopenMainWindow() {
        becomeRegular()
        Self.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title == AppDelegate.mainTitle }
    }

    // MARK: -

    private func windowClosed(_ window: NSWindow?) {
        // A panel closing (the HUD, an alert) says nothing about the windows the user has open.
        guard let window, AppPresencePolicy.isUserWindow(Self.facts(of: window)) else { return }
        // The closing window is left out whatever it still reports; a window opened in the
        // meantime (Settings → main window) is counted.
        let windows = NSApp.windows.filter { $0 !== window }.map(Self.facts(of:))
        if AppPresencePolicy.shouldRunInBackground(windows: windows) {
            NSApp.setActivationPolicy(.accessory)
            Log.app.info("last window closed: running in the menu bar")
        }
    }

    /// SwiftUI opens the main window by itself at launch. A start at login keeps it out of sight:
    /// hidden, not closed, so the menu item and the reopen event still find it.
    private func hideMainWindowOnceCreated() {
        Task { @MainActor in
            for _ in 0..<30 {
                if let window = Self.mainWindow, window.isVisible {
                    window.orderOut(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private static func facts(of window: NSWindow) -> AppPresencePolicy.WindowFacts {
        .init(
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isPanel: window is NSPanel,
            isTitled: window.styleMask.contains(.titled)
        )
    }
}
