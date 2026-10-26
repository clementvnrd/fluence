import Foundation
import Testing

@testable import FluenceCore

/// FLU-37: the wedged grant (switch on, not applied) is told apart from a grant never given,
/// and « Réparer » only ever resets Fluence's own row.
struct AccessibilityGrantTests {
    @Test func untrustedAfterBeingTrustedOnceIsWedged() {
        #expect(AccessibilityGrant.state(isTrusted: false, wasTrustedBefore: true) == .wedged)
    }

    @Test func neverTrustedIsMissingNotWedged() {
        #expect(AccessibilityGrant.state(isTrusted: false, wasTrustedBefore: false) == .missing)
    }

    @Test func trustedIsGrantedWhateverWasStored() {
        #expect(AccessibilityGrant.state(isTrusted: true, wasTrustedBefore: false) == .granted)
        #expect(AccessibilityGrant.state(isTrusted: true, wasTrustedBefore: true) == .granted)
    }

    @Test func theFlagIsSetByATrustedReadAndKeptThroughAnUntrustedOne() {
        #expect(AccessibilityGrant.remembersTrust(isTrusted: true, stored: false))
        #expect(AccessibilityGrant.remembersTrust(isTrusted: false, stored: true))
        #expect(!AccessibilityGrant.remembersTrust(isTrusted: false, stored: false))
    }

    /// The whole sequence: granted, an update re-signs the app, Réparer, granted again.
    @Test func aRepairTurnsTheWedgeIntoAPlainRequest() {
        var stored = false
        func read(_ trusted: Bool) -> AccessibilityGrant.State {
            let state = AccessibilityGrant.state(isTrusted: trusted, wasTrustedBefore: stored)
            stored = AccessibilityGrant.remembersTrust(isTrusted: trusted, stored: stored)
            return state
        }
        #expect(read(false) == .missing)
        #expect(read(true) == .granted)
        #expect(read(false) == .wedged)
        #expect(read(false) == .wedged)
        stored = AccessibilityGrant.afterRepair
        #expect(read(false) == .missing)
        #expect(read(true) == .granted)
    }

    @Test func resetTouchesOnlyThisBundleIDsRow() {
        #expect(AccessibilityGrant.resetArguments(bundleID: "io.github.clementvnrd.fluence")
            == ["reset", "Accessibility", "io.github.clementvnrd.fluence"])
        #expect(AccessibilityGrant.resetArguments(bundleID: "io.github.clementvnrd.fluence.bgtest")?.last
            == "io.github.clementvnrd.fluence.bgtest")
    }

    /// A bare `tccutil reset Accessibility` wipes every app on the Mac: never built.
    @Test func noBundleIDMeansNoReset() {
        #expect(AccessibilityGrant.resetArguments(bundleID: nil) == nil)
        #expect(AccessibilityGrant.resetArguments(bundleID: "") == nil)
        #expect(AccessibilityGrant.resetArguments(bundleID: " ") == nil)
        #expect(AccessibilityGrant.resetArguments(bundleID: "All") == nil)
        #expect(AccessibilityGrant.resetArguments(bundleID: "io.example app") == nil)
        #expect(AccessibilityGrant.resetArguments(bundleID: "-h") == nil)
        #expect(AccessibilityGrant.resetArguments(bundleID: "io.ex;rm") == nil)
    }

    @Test func autoriserOpensOneThingAtATime() {
        #expect(AccessibilityGrant.nextRequest(promptShown: false) == .systemPrompt)
        #expect(AccessibilityGrant.nextRequest(promptShown: true) == .openSettings)
        #expect(AccessibilityGrant.requestTitle(promptShown: false) == "Autoriser l'Accessibilité")
        #expect(AccessibilityGrant.requestTitle(promptShown: true) == "Ouvrir Réglages Système")
    }
}
