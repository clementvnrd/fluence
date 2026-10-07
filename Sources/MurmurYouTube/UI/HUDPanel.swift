import AppKit
import SwiftUI

/// The floating capsule that appears while dictating.
///
/// Designed with a generous transparent canvas (520 x 100) so that the
/// rounded capsule and its soft drop shadow are never clipped by the window edges.
@MainActor
final class HUDPanel: NSPanel {
    init(controller: DictationController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        let hosting = NSHostingView(rootView: HUDView(controller: controller))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Parks the panel just above the Dock, horizontally centered on the active screen.
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
                y: visible.minY + 96
            )
        )
    }

    func present() {
        guard !isVisible || alphaValue < 1 else { return }
        reposition()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard isVisible, alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
            }
        })
    }
}
