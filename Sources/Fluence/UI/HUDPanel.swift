import AppKit
import SwiftUI

/// The floating capsule that appears while you hold the key.
///
/// Clement's capsule sits on a generous transparent canvas (`DS.HUD.size`) so its soft
/// shadow is never clipped; clicks on the transparent part fall through to what's below.
///
/// The single most important property here is that this panel **never becomes key**.
/// If it did, the user's text field would lose focus and `TextInjector` would have
/// nothing to insert into. Hence `.nonactivatingPanel` plus `canBecomeKey == false`.
@MainActor
final class HUDPanel: NSPanel {
    init(controller: DictationController, preview: HUDPreview? = nil) {
        self.controller = controller
        super.init(
            contentRect: NSRect(origin: .zero, size: DS.HUD.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        // The capsule carries a language pill and a finish button, so it takes clicks — and
        // still never focus: `canBecomeKey` is false, so the user's text field keeps it.
        ignoresMouseEvents = false

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // The HUD shows the live transcript. Excluded from screen sharing, recording and
        // screenshots, so dictating during a call doesn't broadcast what you're writing.
        sharingType = .none

        let hosting = ClickThroughHostingView(rootView: HUDView(controller: controller, preview: preview))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = hosting
    }

    private let controller: DictationController

    /// Bumped on every present, so a fade-out that finishes after the HUD was shown again
    /// knows it's stale.
    private var presentation = 0

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Parks the panel just above the Dock, horizontally centered on the active screen.
    ///
    /// `NSScreen.main` is the screen with the *key window* — and an accessory app with a
    /// non-activating panel never has one, so it can be nil. Falling back to `screens.first`
    /// keeps the HUD on-screen instead of stranding it at the origin.
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Log.app.error("no screen available to position HUD")
            return
        }
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + DS.HUD.bottomOffset
            )
        )
    }

    func present() {
        // Every active state change (starting → listening → finishing) calls this. Without
        // the early exit the panel would reset to alpha 0 and re-fade on each one, which
        // reads as a flicker mid-utterance.
        guard !isVisible || alphaValue < 1 else { return }

        presentation += 1
        reposition()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.HUD.fade
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        let presentation = self.presentation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.HUD.fade
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Hopped rather than asserted: see AGENTS.md on `MainActor.assumeIsolated`.
            Task { @MainActor in
                // A fast re-press presented the HUD again while this fade was running;
                // hiding it now would leave the user dictating with no HUD.
                guard let self, self.presentation == presentation else { return }
                self.orderOut(nil)
            }
        }
    }
}

// MARK: FLU-5 input

/// A window that never becomes key only ever receives "first" clicks. Without this, the
/// first click on the Stop key would be spent bringing the panel forward instead of pressing.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
