import Foundation

/// Whether Fluence lives in the Dock or only in the menu bar (FLU-59).
///
/// Dictation, the shortcuts, the HUD and meeting detection do not need a window, so closing
/// the last one must not leave an app in the Dock: Fluence then keeps running in the
/// background, behind its menu bar icon, until the user opens it again from there.
public enum AppPresencePolicy {
    /// What AppKit says about one window, copied out so the rule can be tested.
    public struct WindowFacts: Equatable, Sendable {
        public let isVisible: Bool
        public let isMiniaturized: Bool
        /// The HUD, the meeting pill and alerts are panels, and the HUD and the status item have no
        /// title bar: none of them is "the app being open".
        public let isPanel: Bool
        public let isTitled: Bool

        public init(isVisible: Bool, isMiniaturized: Bool, isPanel: Bool, isTitled: Bool) {
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
            self.isPanel = isPanel
            self.isTitled = isTitled
        }
    }

    /// A kind of window that is part of the app being open: main, settings, correction,
    /// comparison, set-up. Does not depend on whether it is showing, so a window that is closing
    /// can be judged too.
    public static func isUserWindow(_ window: WindowFacts) -> Bool {
        !window.isPanel && window.isTitled
    }

    /// A user window that is on screen or in the Dock. A minimised one still counts, or
    /// minimising would hide the Dock icon the window sits in.
    public static func countsAsOpen(_ window: WindowFacts) -> Bool {
        isUserWindow(window) && (window.isVisible || window.isMiniaturized)
    }

    /// True when no such window is left, so the Dock icon should go.
    public static func shouldRunInBackground(windows: [WindowFacts]) -> Bool {
        !windows.contains(where: countsAsOpen)
    }
}
