import Foundation

/// The app's two clocks. The phone's wall clock can step (set by hand, or corrected by the network), so
/// it stamps things only: when a reading was measured, when a bolus was recorded. Every interval and
/// deadline is timed on `uptime`, which never steps and keeps counting while the phone sleeps, as
/// t:connect times on Android's monotonic clocks and the link on `ContinuousClock`.
public struct SessionClock: Sendable {
    /// The phone's wall clock.
    public var now: @Sendable () -> Date
    /// Seconds on a monotonic clock that counts through sleep. Only differences mean anything.
    public var uptime: @Sendable () -> Double

    /// How far the wall clock can move against the monotonic one before it counts as set: past drift and
    /// the network's small corrections.
    public static let stepTolerance: TimeInterval = 5

    public init(now: @escaping @Sendable () -> Date, uptime: @escaping @Sendable () -> Double) {
        self.now = now
        self.uptime = uptime
    }

    /// `Date()` and `ContinuousClock`, counted from when this is made.
    public static var system: SessionClock {
        let origin = ContinuousClock.now
        return SessionClock(
            now: { Date() },
            uptime: {
                let elapsed = ContinuousClock.now - origin
                return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            })
    }
}

/// Notices the phone's clock being set (by hand, or a large network correction) while the app runs: it
/// shows as a change in the wall clock less the monotonic one. A change within `SessionClock.stepTolerance`
/// is the clocks drifting. Whoever keeps wall-clock stamps that time how long ago something happened moves
/// them by the step it returns.
public struct ClockStepDetector: Sendable {
    private var offset: TimeInterval?

    public init() {}

    /// The step since the last look, in seconds (back when negative), or nil when there was none.
    public mutating func step(_ clock: SessionClock) -> TimeInterval? {
        let now = clock.now().timeIntervalSinceReferenceDate - clock.uptime()
        defer { offset = now }
        guard let last = offset, abs(now - last) > SessionClock.stepTolerance else { return nil }
        return now - last
    }
}
