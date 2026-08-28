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
        case pumpStale  // the pump had a reading but it went stale
        case pumpMissing  // the pump has no reading at all
    }
    /// True while the CURRENTLY-SHOWN live value came from a failover source rather than the pump —
    /// i.e. the pump's own CGM feed (and therefore its own `cgmAlerts`) is unavailable right now. Used
    /// by `UrgentLowAlarm.isActive` (C2-01) so the app-owned alarm fires ONLY in that gap; the pump
    /// remains the primary annunciator whenever its own feed is live.
    public var isFailover: Bool {
        if case .failover = self { return true }
        return false
    }
}

/// **C2-01 — the app-owned urgent-low alarm.** Advisory, source-agnostic: it reads only the already-
/// ARBITRATED live value `GlucoseArbiter.merge` publishes, never a specific source id, and feeds NO
/// dose-path calculation (the app layer posts it through the notification pipeline only). Fires ONLY
/// during a failover (`GlucoseProvenance.isFailover`) — while the pump's own feed is live it remains the
/// sole annunciator (C2-01's add-alongside decision, not a promote/replace of the pump's own cgmAlerts).
public enum UrgentLowAlarm {
    /// 55 mg/dL — Dexcom's OWN published "Urgent Low" alert threshold (a vendor-defined clinical value
    /// this app reuses, not one it invents). Advisory only; never read by the bolus calculator/dose path.
    public static let thresholdMgdl = 55
    public static let dedupeKey = "safety.cgmUrgentLow"
    public static let title = "Urgent low glucose (backup CGM)"
    public static let body =
        "A backup CGM source is reporting an urgent-low reading while the pump's own CGM feed is unavailable. This is advisory only — verify and treat per your care plan."

    /// True iff `mgdl` is at/below `thresholdMgdl` AND the reading is showing via a FAILOVER provenance.
    /// A `nil` mgdl (no live value at all) is never active.
    public static func isActive(mgdl: Int?, provenance: GlucoseProvenance) -> Bool {
        guard provenance.isFailover, let mgdl else { return false }
        return mgdl <= thresholdMgdl
    }
}

@MainActor
public enum GlucoseArbiter {
    /// Produce the snapshot + history the app should publish, given the pump's own data and the
    /// current failover source (if any), plus the provenance of the live value.
    public static func merge(
        pumpSnapshot snap: PumpSnapshot,
        pumpHistory: [GlucoseReading],
        source: GlucoseSource?
    ) -> (PumpSnapshot, [GlucoseReading], GlucoseProvenance) {
        let pumpFresh = snap.glucose != nil && !GlucoseFreshness.isStale(snap.glucoseDate)
        guard !pumpFresh, let source, let sample = source.latest, !sample.isStale else {
            // Pump is fresh, or there is no usable failover — publish pump data unchanged.
            return (snap, pumpHistory, .pump)
        }
        // Fail over: the source's fresh reading becomes the live value.
        var s = snap
        s.glucose = sample.mgdl
        s.glucoseDate = sample.date
        // C8: a source that reports no trend yields NO arrow ("") — not a flat one.
        s.trend = sample.trend?.rawValue ?? ""
        s.cgmActive = true
        let reason: GlucoseProvenance.Reason = (snap.glucose == nil) ? .pumpMissing : .pumpStale
        return (
            s, mergeHistory(pump: pumpHistory, source: source.history),
            .failover(sourceID: sample.sourceID, reason: reason)
        )
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
