import Foundation
import Testing

@testable import FluenceCore

/// FLU-37: an unplugged microphone is shown like a missing grant, by its name.
struct MicrophoneAvailabilityTests {
    @Test func theSystemInputIsAlwaysAvailable() {
        #expect(MicrophoneAvailability.state(selectedUID: "default", availableUIDs: []) == .system)
        #expect(MicrophoneAvailability.state(selectedUID: "", availableUIDs: ["usb-1"]) == .system)
    }

    @Test func aChosenDeviceIsPresentOrUnplugged() {
        #expect(MicrophoneAvailability.state(selectedUID: "usb-1", availableUIDs: ["builtin", "usb-1"]) == .present)
        #expect(MicrophoneAvailability.state(selectedUID: "usb-1", availableUIDs: ["builtin"]) == .unplugged)
        #expect(MicrophoneAvailability.state(selectedUID: "usb-1", availableUIDs: []) == .unplugged)
    }

    @Test func theBannerNamesTheDevice() {
        #expect(MicrophoneAvailability.bannerTitle(rememberedName: "Logitech BRIO") == "Logitech BRIO débranché")
        #expect(MicrophoneAvailability.bannerTitle(rememberedName: nil) == "Micro externe débranché")
        #expect(MicrophoneAvailability.bannerTitle(rememberedName: "  ") == "Micro externe débranché")
        #expect(MicrophoneAvailability.bannerDetail == "Fluence utilise le micro système en attendant.")
    }

    @Test func theSidebarNamesTheInputInUse() {
        #expect(MicrophoneAvailability.inUseName(state: .present, presentName: "Logitech BRIO") == "Logitech BRIO")
        #expect(MicrophoneAvailability.inUseName(state: .unplugged, presentName: nil) == "Micro système")
        #expect(MicrophoneAvailability.inUseName(state: .system, presentName: nil) == "Micro système")
    }
}
