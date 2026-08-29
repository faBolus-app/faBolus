import Foundation

/// Shared "value at a scrubbed timestamp" resolver for the graph-detail readout. Given a scrub
/// `Date` and one of faBolus's own in-memory feed arrays (`[GlucoseReading]` / `[IOBSample]` /
/// `[BolusMarker]`), it returns the sample nearest that instant, or `nil` when the nearest sample is
/// farther than the caller's tolerance — the row then shows an em dash, never a fabricated number.
///
/// Display-only: Foundation only, no dose/delivery/signed-path type. Recovers a value already stored
/// for display; never alters or clinically judges a reading, and nothing it returns is a dose input.
/// The generic `nearest(...)` is the one primitive every readout row is built on.
public enum GraphDetailReadout {

    /// The single sample in `samples` whose `key` `Date` is closest to `date`, provided that closest
    /// sample is within `tolerance` seconds — otherwise `nil`.
    ///
    /// - Empty `samples` ⇒ `nil`.
    /// - Samples on both sides of `date` ⇒ the strictly-closest by absolute time distance.
    /// - The `tolerance` boundary is INCLUSIVE (a sample exactly `tolerance` away is a hit).
    /// - **Tie rule (deterministic):** when two samples are exactly equidistant, the EARLIER one (the
    ///   smaller `Date`) is returned. Stable regardless of the array's original order, so a scrub never
    ///   flickers between two equidistant points.
    ///
    /// Generic over the sample type + its `Date` KeyPath so the same resolver serves glucose, IOB,
    /// and bolus. The caller extracts the value it wants (`.mgdl` / `.iob` / `.units`) from the
    /// returned sample.
    public static func nearest<T>(to date: Date,
                                  in samples: [T],
                                  key: KeyPath<T, Date>,
                                  within tolerance: TimeInterval) -> T? {
        var best: T?
        var bestDelta = TimeInterval.greatestFiniteMagnitude
        var bestDate = Date.distantFuture
        for sample in samples {
            let sampleDate = sample[keyPath: key]
            let delta = abs(sampleDate.timeIntervalSince(date))
            // Strictly closer wins; on an exact tie, the earlier sample wins (deterministic, order-free).
            if delta < bestDelta || (delta == bestDelta && sampleDate < bestDate) {
                best = sample
                bestDelta = delta
                bestDate = sampleDate
            }
        }
        guard best != nil, bestDelta <= tolerance else { return nil }
        return best
    }

    // MARK: - Typed value lookups (thin wrappers over `nearest`)

    /// The mg/dL of the glucose reading nearest `date` within `tolerance`, or `nil` (→ "—") beyond it.
    public static func glucoseMgdl(at date: Date, in readings: [GlucoseReading],
                                   within tolerance: TimeInterval) -> Int? {
        nearest(to: date, in: readings, key: \.date, within: tolerance)?.mgdl
    }

    /// The IOB units of the sample nearest `date` within `tolerance`, or `nil` (→ "—") beyond it.
    public static func iob(at date: Date, in samples: [IOBSample],
                           within tolerance: TimeInterval) -> Double? {
        nearest(to: date, in: samples, key: \.date, within: tolerance)?.iob
    }

    /// The delivered units of the bolus marker nearest `date` within `tolerance`, or `nil` (→ "—")
    /// beyond it. Bolus markers are sparse, so a gap (no bolus near the scrub point) is the norm — it
    /// yields `nil` independent of any glucose/IOB value at the same instant.
    public static func bolusUnits(at date: Date, in markers: [BolusMarker],
                                  within tolerance: TimeInterval) -> Double? {
        nearest(to: date, in: markers, key: \.date, within: tolerance)?.units
    }
}
