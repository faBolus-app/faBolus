import Foundation

/// Where an observed value came from.
public enum ObservationSource: Sendable, Hashable, Codable {
    /// Read from the paired pump.
    case pump
    /// Read from an independent glucose source (`GlucoseSource.id`), used when the pump's own CGM
    /// feed is stale or missing.
    case glucoseSource(id: String)
}

/// One value with the time it describes, the time the app received it, and where it came from.
///
/// Every pump-derived value is held this way, and a value the app hasn't read is `nil`, never a zero
/// placeholder: `0 U` in the reservoir and `0 %` battery are real readings, so absence must not be able
/// to imitate them.
///
/// Staleness is measured from `measuredAt`, the pump's own time for the value, so re-reading the same
/// old CGM sample on every poll never makes it look new. A value the pump reports with no timestamp
/// of its own (battery, IOB) is measured when the pump answered, which the reader sets to the reply's
/// receipt time.
public struct Observed<Value: Sendable>: Sendable {
    public var value: Value
    /// When the value was true, by the clock of whatever measured it.
    public var measuredAt: Date
    /// When this app received it.
    public var receivedAt: Date
    public var source: ObservationSource

    public init(_ value: Value, measuredAt: Date, receivedAt: Date, source: ObservationSource = .pump) {
        self.value = value
        self.measuredAt = measuredAt
        self.receivedAt = receivedAt
        self.source = source
    }

    /// A measurement dated further than this ahead of the time it was received or of `now` came from
    /// a fast clock. Its real age can't be known, so it counts as stale rather than as current. The
    /// calculator inputs' tolerance, so every freshness check shares one rule.
    public static var futureSkewTolerance: TimeInterval { CalcInputFreshness.futureSkewTolerance }

    /// Whether `measuredAt` can be trusted as the value's time: finite, and not dated in the future
    /// beyond clock skew relative to when it arrived.
    public var hasValidTime: Bool {
        measuredAt.timeIntervalSince1970.isFinite && receivedAt.timeIntervalSince1970.isFinite
            && measuredAt.timeIntervalSince(receivedAt) <= Self.futureSkewTolerance
    }

    /// How old the value is at `now`, or `nil` when its time can't be trusted (see `hasValidTime`, and
    /// a measurement dated in the future of `now` beyond clock skew). Never negative.
    public func age(now: Date = Date()) -> TimeInterval? {
        guard hasValidTime, now.timeIntervalSince1970.isFinite else { return nil }
        let elapsed = now.timeIntervalSince(measuredAt)
        guard elapsed >= -Self.futureSkewTolerance else { return nil }
        return max(0, elapsed)
    }

    /// True when the value is older than `window` at `now`, or when its age can't be known. Fail closed:
    /// an untrustworthy time is stale, never current.
    public func isStale(after window: TimeInterval, now: Date = Date()) -> Bool {
        guard hasValidTime, now.timeIntervalSince1970.isFinite else { return true }
        return CalcInputFreshness.isStale(measuredAt, staleAfter: window, now: now)
    }

    /// The value while it is no older than `window`, else `nil`. The gate is the value's age, never its
    /// value: a fresh `0` is returned as `0`.
    public func valueIfFresh(within window: TimeInterval, now: Date = Date()) -> Value? {
        isStale(after: window, now: now) ? nil : value
    }

    /// The same observation with a transformed value.
    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> Observed<T> {
        Observed<T>(try transform(value), measuredAt: measuredAt, receivedAt: receivedAt, source: source)
    }
}

extension Observed: Equatable where Value: Equatable {}
extension Observed: Hashable where Value: Hashable {}
extension Observed: Codable where Value: Codable {}
