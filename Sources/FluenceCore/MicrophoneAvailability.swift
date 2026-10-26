import Foundation

/// Whether the microphone chosen in Réglages is plugged in (FLU-37).
///
/// When it is not, `AudioCapture` records from the system input instead; the main window says
/// so the way it says Accessibility is missing — an amber banner that names the device. The
/// name is remembered when the device is chosen, because an unplugged device is no longer in
/// the system's list. A device name is not personal data, but it is never logged either.
public enum MicrophoneAvailability {
    /// The stored value for « Système (par défaut) ».
    public static let systemUID = "default"

    public enum State: Equatable, Sendable {
        /// Dictation follows the system input.
        case system
        /// The chosen device is connected.
        case present
        /// The chosen device is gone; the system input stands in.
        case unplugged
    }

    public static func state(selectedUID: String, availableUIDs: [String]) -> State {
        if selectedUID.isEmpty || selectedUID == systemUID { return .system }
        return availableUIDs.contains(selectedUID) ? .present : .unplugged
    }

    /// « Logitech BRIO débranché », or « Micro externe débranché » without a remembered name.
    public static func bannerTitle(rememberedName: String?) -> String {
        let name = rememberedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (name.isEmpty ? "Micro externe" : name) + " débranché"
    }

    public static let bannerDetail = "Fluence utilise le micro système en attendant."

    /// The name under the brand in the sidebar: the device in use. Unplugged, that is the
    /// system input, not « Micro externe ».
    public static func inUseName(state: State, presentName: String?) -> String {
        switch state {
        case .present: presentName ?? "Micro externe"
        case .system, .unplugged: "Micro système"
        }
    }
}
