import Foundation

/// When to redo a periodic check in a block-by-block audio loop (the mic channel re-reads
/// the output route every ~2 s): on the first block, then once every `interval` blocks.
///
/// The counter resets at each check, so it never grows past `interval` however long the
/// meeting runs. Swift traps on integer overflow, so seeding a counter with `Int.max` to
/// force the first check is not an option (FLU-15).
public struct BlockSchedule: Sendable {
    public let interval: Int
    /// Blocks since the last check; `nil` before the first block.
    private var sinceLast: Int?

    public init(every interval: Int) {
        self.interval = max(1, interval)
    }

    /// Call once per block; true when the check is due on this block.
    public mutating func tick() -> Bool {
        if let sinceLast, sinceLast + 1 < interval {
            self.sinceLast = sinceLast + 1
            return false
        }
        sinceLast = 0
        return true
    }
}
