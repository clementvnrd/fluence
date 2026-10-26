import Foundation

/// Whether macOS applies Fluence's Accessibility grant (FLU-37).
///
/// The damaging case is the wedge: System Settings still shows Fluence's switch on, but macOS
/// no longer applies it — TCC stored the code-signing requirement of an earlier build (an
/// update, a re-signed copy), and `AXIsProcessTrusted` answers false. From the outside it looks
/// exactly like a grant never given, so the app remembers that it was trusted once (a flag set
/// whenever `AXIsProcessTrusted` is seen true) and reads « untrusted after that » as wedged.
public enum AccessibilityGrant {
    public enum State: Equatable, Sendable {
        case granted
        /// Never given, or removed by « Réparer » and not given again yet.
        case missing
        /// Given once, not applied any more: the switch shows on, nothing gets typed.
        case wedged
    }

    public static func state(isTrusted: Bool, wasTrustedBefore: Bool) -> State {
        if isTrusted { return .granted }
        return wasTrustedBefore ? .wedged : .missing
    }

    /// What the « trusted once » flag becomes after a read: set by any trusted read, and only
    /// cleared by a repair (`afterRepair`), never by an untrusted read — that is the wedge.
    public static func remembersTrust(isTrusted: Bool, stored: Bool) -> Bool {
        isTrusted || stored
    }

    /// After « Réparer » removed the row the flag is cleared, so the page that follows asks
    /// for the grant (« Réactivez Fluence ») instead of showing the wedge again.
    public static let afterRepair = false

    /// The arguments of `/usr/bin/tccutil` for « Réparer »: this bundle ID's Accessibility row
    /// and nothing else. Nil without a usable bundle ID — a bare `tccutil reset Accessibility`
    /// wipes every app's grant on the Mac (AGENTS.md), so it is never run.
    public static func resetArguments(bundleID: String?) -> [String]? {
        guard let bundleID, !bundleID.isEmpty,
              bundleID.unicodeScalars.allSatisfy({ allowedInBundleID.contains($0) }),
              bundleID.contains("."), !bundleID.hasPrefix("."), !bundleID.hasPrefix("-")
        else { return nil }
        return ["reset", "Accessibility", bundleID]
    }

    /// Letters, digits, hyphens and dots: what a bundle identifier is made of.
    private static let allowedInBundleID = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
    )

    /// What one press of « Autoriser l'Accessibilité » opens: one thing at a time. First the
    /// system prompt, which puts Fluence in the list and offers its own way to System Settings;
    /// once it has been shown, System Settings itself.
    public enum Request: Equatable, Sendable {
        case systemPrompt
        case openSettings
    }

    public static func nextRequest(promptShown: Bool) -> Request {
        promptShown ? .openSettings : .systemPrompt
    }

    /// The button's title for that press.
    public static func requestTitle(promptShown: Bool) -> String {
        switch nextRequest(promptShown: promptShown) {
        case .systemPrompt: "Autoriser l'Accessibilité"
        case .openSettings: "Ouvrir Réglages Système"
        }
    }
}
