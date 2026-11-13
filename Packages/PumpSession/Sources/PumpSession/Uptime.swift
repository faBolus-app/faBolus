import Foundation

/// A moment on the session's monotonic clock (`SessionClock.uptime`). Its methods are `Date`'s, so a
/// deadline reads the same either way; being its own type, it can't be compared with a wall-clock time.
struct Uptime: Comparable, Hashable, Sendable {
    let seconds: Double

    func addingTimeInterval(_ interval: TimeInterval) -> Uptime { Uptime(seconds: seconds + interval) }
    func timeIntervalSince(_ earlier: Uptime) -> TimeInterval { seconds - earlier.seconds }

    static func < (a: Uptime, b: Uptime) -> Bool { a.seconds < b.seconds }
}
