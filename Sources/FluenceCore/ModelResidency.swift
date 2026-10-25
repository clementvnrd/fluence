import Foundation

/// When a loaded speech model may leave memory (FLU-31).
///
/// Parakeet holds about 0.6 GB of Neural Engine memory once loaded, and used to keep it for
/// the life of the process. It now leaves after `idleLimit` without use, or at once when the
/// system says memory is short — never while a dictation or a meeting utterance is using it,
/// and never in the middle of a load. The next key-down loads it again while the user talks
/// (a fraction of a second from the compiled cache), so release does not pay for it.
public enum ModelResidency {
    /// Ten minutes: the model is gone well inside the 15-minute budget, and a burst of
    /// dictations a few minutes apart never reloads.
    public static let idleLimit: TimeInterval = 10 * 60

    public enum Trigger: Equatable, Sendable {
        /// The idle timer fired.
        case idle
        /// The system reported memory pressure (warning or critical).
        case memoryPressure
    }

    public struct State: Equatable, Sendable {
        public var isLoaded: Bool
        /// A load is in flight: unloading now would only waste it.
        public var isLoading: Bool
        /// Dictations or meeting utterances holding the model right now.
        public var usersInFlight: Int
        /// Seconds since the model was last used, or nil if it never was since loading.
        public var idleSeconds: TimeInterval?

        public init(isLoaded: Bool, isLoading: Bool = false, usersInFlight: Int = 0, idleSeconds: TimeInterval?) {
            self.isLoaded = isLoaded
            self.isLoading = isLoading
            self.usersInFlight = usersInFlight
            self.idleSeconds = idleSeconds
        }
    }

    public static func shouldUnload(_ state: State, trigger: Trigger, idleLimit: TimeInterval = idleLimit) -> Bool {
        guard state.isLoaded, !state.isLoading, state.usersInFlight <= 0 else { return false }
        switch trigger {
        case .memoryPressure:
            return true
        case .idle:
            // Loaded but never used (a prewarm at launch) counts as idle since the load.
            return (state.idleSeconds ?? .infinity) >= idleLimit
        }
    }

    /// How long until the idle timer should look again, or nil when no timer is needed: not
    /// loaded, or in use (the end of that use starts the timer).
    public static func nextCheck(_ state: State, idleLimit: TimeInterval = idleLimit) -> TimeInterval? {
        guard state.isLoaded, state.usersInFlight <= 0 else { return nil }
        guard let idle = state.idleSeconds else { return 0 }
        return max(0, idleLimit - idle)
    }
}
