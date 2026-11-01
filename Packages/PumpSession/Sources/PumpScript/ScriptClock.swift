import Foundation
import TandemBLE
import TandemLink
import os

/// A clock whose time moves only when told to. While `suspended`, nothing fires, as on iOS when the app is
/// suspended; timers that came due fire on `resume()`. It is the link's clock and, through `date`, the
/// session's, so link timers and the session's own timing stay in step.
@MainActor
public final class ScriptClock: LinkClock {
    public private(set) var now: LinkTime = 0
    public var suspended = false
    private let origin: Date
    private let shared: OSAllocatedUnfairLock<LinkTime>
    private var scheduled: [(due: LinkTime, token: Token, action: @MainActor () -> Void)] = []

    public final class Token: LinkClockToken {
        var cancelled = false
        public func cancel() { cancelled = true }
    }

    public init(origin: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.origin = origin
        shared = OSAllocatedUnfairLock(initialState: 0)
    }

    /// The wall-clock time now, readable from any isolation domain.
    public nonisolated var date: Date { origin.addingTimeInterval(shared.withLock { $0 }) }

    public func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) -> any LinkClockToken {
        let token = Token()
        scheduled.append((now + seconds, token, action))
        return token
    }

    /// Moves time forward, firing each timer that comes due in order (unless suspended).
    public func advance(by seconds: Double) {
        let end = now + seconds
        while !suspended,
            let next = scheduled.enumerated().filter({ !$0.element.token.cancelled && $0.element.due <= end })
                .min(by: { $0.element.due < $1.element.due })
        {
            scheduled.remove(at: next.offset)
            set(max(now, next.element.due))
            next.element.action()
        }
        set(end)
        scheduled.removeAll { $0.token.cancelled }
    }

    public func resume() {
        suspended = false
        advance(by: 0)
    }

    private func set(_ time: LinkTime) {
        now = time
        shared.withLock { $0 = time }
    }
}
