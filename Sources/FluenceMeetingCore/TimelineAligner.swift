import Foundation

/// Keeps one channel's samples on the meeting clock.
///
/// Both channels are stamped with the host clock, but devices run on their own clocks,
/// stall on route changes and restart after a sleep. Each channel is therefore written as
/// one continuous timeline where sample *i* is meeting time *i / sampleRate*: gaps become
/// silence, overlaps are trimmed. That single invariant is what lets the echo canceller
/// pair mic and system samples, the diarizer's times line up with the transcript, and the
/// spool be indexed by time.
///
/// Small jitter (under `tolerance`) is absorbed rather than corrected, so a healthy stream
/// is written untouched.
public struct TimelineAligner: Sendable {
    public struct Placement: Sendable, Equatable {
        /// Zeros to write before the chunk.
        public var padding: Int
        /// Samples to drop from the front of the chunk.
        public var dropLeading: Int

        public init(padding: Int, dropLeading: Int) {
            self.padding = padding
            self.dropLeading = dropLeading
        }
    }

    public let sampleRate: Double
    public let tolerance: Int
    /// Samples written so far: the timeline's current length.
    public private(set) var written: Int = 0

    public init(sampleRate: Double = 16_000, tolerance: TimeInterval = 0.12) {
        self.sampleRate = sampleRate
        self.tolerance = Int(tolerance * sampleRate)
    }

    /// Where to put a chunk of `count` samples whose first sample was captured at
    /// `time` seconds after the meeting start. Advances the timeline.
    public mutating func place(time: TimeInterval, count: Int) -> Placement {
        let expected = Int((max(0, time) * sampleRate).rounded())
        let gap = expected - written
        var placement = Placement(padding: 0, dropLeading: 0)
        if gap > tolerance {
            placement.padding = gap
        } else if gap < -tolerance {
            placement.dropLeading = min(-gap, count)
        }
        written += placement.padding + count - placement.dropLeading
        return placement
    }

    /// Extends the timeline with silence up to `time` (used when a channel has delivered
    /// nothing, e.g. while a tap is being rebuilt). Returns the zeros to write.
    public mutating func padUntil(time: TimeInterval) -> Int {
        let expected = Int((max(0, time) * sampleRate).rounded())
        let gap = expected - written
        guard gap > tolerance else { return 0 }
        written += gap
        return gap
    }
}
