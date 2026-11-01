import Foundation

/// Freshness for the bolus calculator's inputs: IOB (op-109) and the therapy settings (op-115), the
/// counterpart of `GlucoseFreshness`. The windows come from `FreshnessThresholds`: IOB moves all the time
/// and is subtracted from the dose, so its window is tighter than the settings', which change only when
/// the pump is edited or a profile segment starts. A value past its window never sizes a dose without a
/// prompt.
public enum CalcInputFreshness {
    /// Clock-skew tolerance for **future-dated** reads, mirroring `GlucoseFreshness.futureSkewTolerance`. A
    /// read whose stamp is more than this far ahead of `now` came from a fast clock; its true age is
    /// unknowable, so it is treated as stale rather than trusted. Without this, a future-dated read has a
    /// negative elapsed time that `isStale` would read as "fresh" and it would never age out.
    public static let futureSkewTolerance: TimeInterval = 5 * 60

    /// Age of a read taken at `date` (never negative).
    public static func age(of date: Date, now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(date))
    }

    /// Core staleness test against an explicit threshold. A nil date → stale (we have not confirmed a fresh
    /// value). A date more than `futureSkewTolerance` in the FUTURE is also stale (untrustworthy clock).
    /// A window that isn't a finite, non-negative number makes every reading stale: an infinite or NaN
    /// window would otherwise never expire anything.
    public static func isStale(_ date: Date?, staleAfter: TimeInterval, now: Date = Date()) -> Bool {
        guard let date, staleAfter.isFinite, staleAfter >= 0 else { return true }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < -futureSkewTolerance { return true }  // dated in the future beyond clock skew
        return elapsed > staleAfter
    }

    /// True when the IOB read taken at `date` is stale (nil → stale).
    public static func isIobStale(_ date: Date?, thresholds: FreshnessThresholds, now: Date = Date()) -> Bool {
        isStale(date, staleAfter: thresholds.insulinOnBoardStaleAfter, now: now)
    }

    /// True when the therapy-settings read taken at `date` is stale (nil → stale).
    public static func isTherapyStale(_ date: Date?, thresholds: FreshnessThresholds, now: Date = Date()) -> Bool {
        isStale(date, staleAfter: thresholds.therapyStaleAfter, now: now)
    }

    /// How a read of a given age should be presented on screen (3-state), against an explicit threshold.
    /// `nil` date → `.stale` (unknown age is conservative). There is no separate "hide" age for calc
    /// inputs — an absent/stale input is surfaced (and, on the dose path, blocks), never silently dropped —
    /// so this is fresh/stale, with `.hidden` reserved for a caller that has literally no value to show.
    public static func presentation(of date: Date?, staleAfter: TimeInterval, now: Date = Date())
        -> CalcInputPresentation
    {
        guard let date, staleAfter.isFinite, staleAfter >= 0 else { return .stale }
        let age = now.timeIntervalSince(date)
        if age < -futureSkewTolerance { return .stale }  // future-dated beyond clock skew → stale, never fresh
        return age <= staleAfter ? .fresh : .stale
    }

    /// Presentation for an IOB read.
    public static func iobPresentation(
        of date: Date?, thresholds: FreshnessThresholds, now: Date = Date()
    ) -> CalcInputPresentation {
        date == nil ? .hidden : presentation(of: date, staleAfter: thresholds.insulinOnBoardStaleAfter, now: now)
    }

    /// Presentation for a therapy-params read.
    public static func therapyPresentation(
        of date: Date?, thresholds: FreshnessThresholds, now: Date = Date()
    ) -> CalcInputPresentation {
        date == nil ? .hidden : presentation(of: date, staleAfter: thresholds.therapyStaleAfter, now: now)
    }

    /// Compact relative age label, identical in form to `GlucoseFreshness.ageLabel` ("now", "3 min ago",
    /// "1h 12m ago"), so an IOB / therapy row reads the same as a glucose row.
    public static func ageLabel(for date: Date, now: Date = Date()) -> String {
        let s = Int(age(of: date, now: now))
        if s < 30 { return "now" }
        if s < 3600 { return "\(max(1, s / 60)) min ago" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)h ago" : "\(h)h \(m)m ago"
    }
}

/// How a calc-input read should be shown, by age (see `CalcInputFreshness`). Mirrors `GlucosePresentation`.
public enum CalcInputPresentation: Sendable, Equatable {
    case fresh  // within the threshold — normal styling, live value
    case stale  // past the threshold — shown de-emphasized (grey) with its age
    case hidden  // no value at all to show ("--")
}
