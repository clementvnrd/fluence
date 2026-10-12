import AppKit
import ApplicationServices
import FluenceCore
import Foundation

/// Where a dictation is going: the frontmost app at key release, and its category.
///
/// FLU-5 text. Only the category leaves this file. A browser's front-tab address is read
/// through Accessibility to classify Gmail or Slack in a tab, used once, and dropped: it is
/// never stored, logged or attached to the dictation.
@MainActor
enum FrontmostApp {
    struct Target: Sendable {
        let bundleID: String?
        let category: AppCategory
    }

    /// A front tab is found within a handful of levels; the caps bound the walk on a window
    /// exposing thousands of elements, or a browser too busy to answer, since this runs
    /// while the user waits for their text.
    private static let maxNodes = 300
    private static let budget: Duration = .milliseconds(150)
    private static let axTimeout: Float = 0.1

    /// - Parameter readURL: whether to look at a browser's front tab at all. Only level High
    ///   uses the category, so lower levels never read the address.
    static func capture(readURL: Bool) -> Target {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return Target(bundleID: nil, category: .other)
        }
        let bundleID = app.bundleIdentifier
        var url: String?
        if readURL, let bundleID, AppCategory.isBrowser(bundleID: bundleID) {
            url = frontTabURL(pid: app.processIdentifier)
        }
        return Target(bundleID: bundleID, category: AppCategory.classify(bundleID: bundleID, url: url))
    }

    /// The address of the focused window's page, if the browser exposes it.
    ///
    /// Two places, cheapest first: Safari and most WebKit browsers put the page URL in the
    /// window's `AXDocument`; Chromium browsers expose it as `AXURL` on the `AXWebArea`.
    private static func frontTabURL(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        // Elements reached from `app` don't inherit its timeout, so it's set system-wide for
        // the walk and put back to `TextInjector`'s value afterwards.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axTimeout)
        defer { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXRead.appTimeout) }
        let deadline = ContinuousClock.now + budget
        guard let window = AXRead.element(app, kAXFocusedWindowAttribute) else { return nil }

        if let document = AXRead.string(window, kAXDocumentAttribute), document.contains(".") {
            return document
        }

        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes, ContinuousClock.now < deadline {
            let element = queue.removeFirst()
            visited += 1
            if AXRead.string(element, kAXRoleAttribute) == "AXWebArea" {
                if let url = AXRead.copy(element, kAXURLAttribute) as? URL { return url.absoluteString }
                continue // a page's own elements never hold its address
            }
            queue.append(contentsOf: AXRead.elements(element, kAXChildrenAttribute))
        }
        return nil
    }
}

/// Typed reads of Accessibility attributes. The casts go through `CFGetTypeID` and
/// `unsafeDowncast`, as `TextInjector` does: an attribute can hold any CF type, and a
/// conditional cast to a CF class always "succeeds" whatever the object really is.
enum AXRead {
    /// The app-wide Accessibility timeout `TextInjector` sets (its `axTimeout`), restored
    /// after a shorter one is used for a walk. Kept equal to it by hand: a hung app must
    /// never freeze Fluence for the 6-second default.
    static let appTimeout: Float = 0.5

    static func copy(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = copy(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let array = copy(element, name) as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeDowncast(item, to: AXUIElement.self) : nil
        }
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        copy(element, name) as? String
    }

    static func range(_ element: AXUIElement, _ name: String) -> CFRange? {
        guard let value = copy(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    static func focusedElement() -> AXUIElement? {
        element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
    }
}
