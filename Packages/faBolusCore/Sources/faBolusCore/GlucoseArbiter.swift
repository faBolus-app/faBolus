import Foundation

/// Merges the pump-relayed glucose (**primary**) with an optional independent `GlucoseSource`
/// (**failover**). The rule that governs everything: a stale reading is never presented as the
/// current value.
///
/// - The pump feed stays primary while it is fresh.
/// - When the pump feed is stale/missing **and** a source has a fresh reading, the source takes over
///   the live value and its history is merged in.
/// - If everything is stale, the pump's own (stale) value is kept and the UI flags it via
///   `PumpSnapshot.isGlucoseStale` — "old is worse than nothing", so it is shown marked, not as live.
/// Where the currently-published live glucose value came from — so the UI can surface a small
/// "via <source>" badge (and *why*) whenever the pump feed isn't the one being shown.
public enum GlucoseProvenance: Equatable, Sendable {
    case pump
    case failover(sourceID: String, reason: Reason)
    public enum Reason: String, Sendable, Equatable {
        case pumpStale    // the pump had a reading but it went stale
        case pumpMissing  // the pump has no reading at all
    }
}

@MainActor
public enum GlucoseArbiter {
    /// Produce the snapshot + history the app should publish, given the pump's own data and the
    /// current failover source (if any), plus the provenance of the live value.
    public static func merge(pumpSnapshot snap: PumpSnapshot,
                             pumpHistory: [GlucoseReading],
                             source: GlucoseSource?) -> (PumpSnapshot, [GlucoseReading], GlucoseProvenance) {
        let pumpFresh = snap.glucose != nil && !GlucoseFreshness.isStale(snap.glucoseDate)
        guard !pumpFresh, let source, let sample = source.latest, !sample.isStale else {
            // Pump is fresh, or there is no usable failover — publish pump data unchanged.
            return (snap, pumpHistory, .pump)
        }
        // Fail over: the source's fresh reading becomes the live value.
        var s = snap
        s.glucose = sample.mgdl
        s.glucoseDate = sample.date
        s.trend = sample.trend.rawValue
        s.cgmActive = true
        let reason: GlucoseProvenance.Reason = (snap.glucose == nil) ? .pumpMissing : .pumpStale
        return (s, mergeHistory(pump: pumpHistory, source: source.history),
                .failover(sourceID: sample.sourceID, reason: reason))
    }

    /// Union of pump + source history, de-duplicated into 5-minute buckets (pump wins ties so the
    /// chart never double-counts the same reading), sorted oldest→newest.
    public static func mergeHistory(pump: [GlucoseReading], source: [GlucoseReading]) -> [GlucoseReading] {
        let bucket = 5.0 * 60
        var byBucket: [Int: GlucoseReading] = [:]
        for r in source { byBucket[Int(r.date.timeIntervalSince1970 / bucket)] = r }
        for r in pump { byBucket[Int(r.date.timeIntervalSince1970 / bucket)] = r }  // pump wins ties
        return byBucket.values.sorted { $0.date < $1.date }
    }
}
