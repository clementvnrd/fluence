import Foundation

/// The *Réunion détectée* card's clock (FLU-34): what each one-second tick does while the
/// card is up.
///
/// Ignoring the card is not consent. By default nothing records until the user clicks
/// *Enregistrer*; recording on its own after a delay happens only when the user chose a
/// delay in Settings (*Enregistrer sans clic*), and the card then shows it counting down.
public struct DetectionOffer: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Keep the card up.
        case wait
        /// The delay the user chose has run out: start recording.
        case record
        /// The call ended before anyone answered: take the card down.
        case withdraw
    }

    /// The delays offered in Settings; 0 is *Jamais* (wait for a click), the default.
    public static let autoRecordChoices = [0, 10, 20, 30, 60]

    /// Seconds left before recording starts on its own; `nil` waits for a click.
    public private(set) var remaining: Int?
    /// The delay the card counts down from, for its ring; `nil` without one.
    public let total: Int?

    /// `autoRecordSeconds`: the Settings delay, 0 (or less) for none.
    public init(autoRecordSeconds: Int) {
        total = autoRecordSeconds > 0 ? autoRecordSeconds : nil
        remaining = total
    }

    /// One second passed. `callOngoing`: the meeting app still holds the microphone.
    public mutating func tick(callOngoing: Bool) -> Step {
        guard callOngoing else { return .withdraw }
        guard let left = remaining else { return .wait }
        if left <= 1 {
            remaining = 0
            return .record
        }
        remaining = left - 1
        return .wait
    }
}
