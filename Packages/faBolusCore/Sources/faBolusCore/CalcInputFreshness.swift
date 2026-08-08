import Foundation
import os

/// Freshness policy for the **bolus-calculator inputs** the pump reports — active insulin (IOB) and the
/// therapy parameters (carb ratio / ISF / target). It is the exact analogue of `GlucoseFreshness` for the
/// glucose feed: one definition of "stale" per input so the dose path and the UI agree, adjustable at
/// runtime, and — critically — a value past its threshold is never trusted to size an authoritative dose.
///
/// Why two thresholds. The pump caches these on very different cadences: op-109 IOB advances continuously
/// (a fresh read every ~60 s), while op-115 therapy params (CR/ISF/target/max) only change when a
/// clinician/user edits the pump or a scheduled profile time-segment boundary crosses. IOB going a few
/// minutes stale is a real dosing hazard (active insulin is being subtracted from the correction), so it
/// gets the tighter window; therapy params tolerate a wider one.
///
/// **Thresholds are owner-confirmable defaults.** 300 s (IOB) and 900 s (therapy) are the design starting
/// points, recorded for the §13 clinical-review gate. They can be tuned at launch (e.g. from Settings) the
/// same way `GlucoseFreshness.staleAfter` is; a clinician/CDCES review is required before any real-insulin
/// or `experimental` distribution (see `dosing-input-freshness-plan-2026-08-07.md`).
public enum CalcInputFreshness {
    // Thread-safe backing (audit A-09), mirroring `GlucoseFreshness`: set at launch and read from many
    // isolation domains, so an `OSAllocatedUnfairLock` gives a genuinely-safe shared store rather than a
    // `nonisolated(unsafe) static var` (which only silences the checker).
    private static let _staleAfterIob = OSAllocatedUnfairLock<TimeInterval>(initialState: 300)        // 5 min
    private static let _staleAfterTherapy = OSAllocatedUnfairLock<TimeInterval>(initialState: 900)    // 15 min

    /// Active-insulin (IOB) readings older than this are **stale**: shown de-emphasized and never used to
    /// size an authoritative dose without an explicit warned override. Owner-confirmable default: 300 s.
    public static var staleAfterIob: TimeInterval {
        get { _staleAfterIob.withLock { $0 } }
        set { _staleAfterIob.withLock { $0 = newValue } }
    }

    /// Therapy parameters (carb ratio / ISF / target) older than this are **stale**. Owner-confirmable
    /// default: 900 s. Wider than IOB because these change only on a pump edit or a scheduled
    /// profile-segment boundary, not continuously.
    public static var staleAfterTherapy: TimeInterval {
        get { _staleAfterTherapy.withLock { $0 } }
        set { _staleAfterTherapy.withLock { $0 = newValue } }
    }

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
    public static func isStale(_ date: Date?, staleAfter: TimeInterval, now: Date = Date()) -> Bool {
        guard let date else { return true }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < -futureSkewTolerance { return true }   // dated in the future beyond clock skew
        return elapsed > staleAfter
    }

    /// True when the IOB read taken at `date` is stale per `staleAfterIob` (nil → stale).
    public static func isIobStale(_ date: Date?, now: Date = Date()) -> Bool {
        isStale(date, staleAfter: staleAfterIob, now: now)
    }

    /// True when the therapy-params read taken at `date` is stale per `staleAfterTherapy` (nil → stale).
    public static func isTherapyStale(_ date: Date?, now: Date = Date()) -> Bool {
        isStale(date, staleAfter: staleAfterTherapy, now: now)
    }

    /// How a read of a given age should be presented on screen (3-state), against an explicit threshold.
    /// `nil` date → `.stale` (unknown age is conservative). There is no separate "hide" age for calc
    /// inputs — an absent/stale input is surfaced (and, on the dose path, blocks), never silently dropped —
    /// so this is fresh/stale, with `.hidden` reserved for a caller that has literally no value to show.
    public static func presentation(of date: Date?, staleAfter: TimeInterval, now: Date = Date()) -> CalcInputPresentation {
        guard let date else { return .stale }
        let age = now.timeIntervalSince(date)
        if age < -futureSkewTolerance { return .stale }     // future-dated beyond clock skew → stale, never fresh
        return age <= staleAfter ? .fresh : .stale
    }

    /// Presentation for an IOB read.
    public static func iobPresentation(of date: Date?, now: Date = Date()) -> CalcInputPresentation {
        date == nil ? .hidden : presentation(of: date, staleAfter: staleAfterIob, now: now)
    }

    /// Presentation for a therapy-params read.
    public static func therapyPresentation(of date: Date?, now: Date = Date()) -> CalcInputPresentation {
        date == nil ? .hidden : presentation(of: date, staleAfter: staleAfterTherapy, now: now)
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
    case fresh      // within the threshold — normal styling, live value
    case stale      // past the threshold — shown de-emphasized (grey) with its age
    case hidden     // no value at all to show ("--")
}
