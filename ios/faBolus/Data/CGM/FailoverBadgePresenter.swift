import Foundation
import faBolusCore

/// Pure presentation/formatting mappers for the failover badge, short source name, and the two
/// status-push / snooze-gate predicates. `failoverBadge` takes the already-computed
/// `GlucoseProvenance` value IN and never reads `AppModel`'s `source`/snapshot live — no second
/// source of pump truth. `shouldPushStatus`/`snoozeGateAllows` are pure value-in/value-out
/// predicates with no `AppModel`/singleton/clock read of their own.
///
/// `failoverBadge` is `@MainActor` because `GlucoseSourceRegistry.descriptor(id:)` (its one
/// dependency) is itself `@MainActor`. `shortSourceName`/`shouldPushStatus`/`snoozeGateAllows` stay
/// free of actor isolation.
enum FailoverBadgePresenter {

    /// A short source name + human reason when the live glucose is coming from a **failover** source
    /// instead of the pump; `nil` when the pump feed is live (`provenance == .pump`). Value-in
    /// (`provenance`) / value-out, no live read.
    @MainActor
    static func failoverBadge(provenance: GlucoseProvenance) -> (name: String, reason: String)? {
        guard case let .failover(sourceID, reason) = provenance else { return nil }
        let full = GlucoseSourceRegistry.descriptor(id: sourceID)?.name ?? sourceID
        let name = shortSourceName(full)
        switch reason {
        case .pumpMissing: return (name, "Showing \(full) — the pump has no CGM reading.")
        case .pumpStale: return (name, "Showing \(full) — the pump's CGM reading went stale.")
        }
    }

    /// A compact source name for the small "via …" failover badge — drops the parenthetical/qualifier
    /// so no source name overruns the ring (e.g. "Dexcom Share (cloud)" → "Dexcom Share",
    /// "Dexcom G7 / ONE+ (direct BLE)" → "Dexcom G7").
    static func shortSourceName(_ full: String) -> String {
        var s = full
        for sep in [" (", " — ", " / "] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a status push is due. Pushes immediately (bypassing the 15 s throttle) on a NEW
    /// glucose SAMPLE — identified by its source timestamp, so a fresh reading at an unchanged mg/dL
    /// still pushes (comparing the value only would silently drop a repeated number from remotes) —
    /// on any connection-state change (the watch sees the bolus start + the settle instantly), and
    /// continuously while a bolus is in progress; otherwise at most once per throttle window to spare
    /// phone + watch battery. Pure, so the cadence rule is unit-testable.
    static func shouldPushStatus(
        newGlucose: Int?, newGlucoseDate: Date?,
        lastGlucose: Int?, lastGlucoseDate: Date?,
        newConnection: PumpConnectionState, lastConnection: PumpConnectionState?,
        secondsSinceLastPush: TimeInterval, throttle: TimeInterval = 15
    ) -> Bool {
        let newSample = newGlucose != lastGlucose || newGlucoseDate != lastGlucoseDate
        let connChanged = newConnection != lastConnection
        let bolusing = newConnection == .bolusing
        return newSample || connChanged || bolusing || secondsSinceLastPush > throttle
    }

    /// The SINGLE "can Snooze actually do anything right now" predicate, fed into
    /// `WidgetPublisher.publish`'s `hasSnoozeEligibleAlert` parameter (`WidgetSnapshot`).
    /// True only when there's at least one active alert AND none of them is `.alarm` (an `.alarm`
    /// blocks snoozing entirely). Pure — no `AppModel` state read beyond the alerts array handed in.
    static func snoozeGateAllows(_ alerts: [PumpAlert]) -> Bool {
        !alerts.isEmpty && !alerts.contains(where: { !$0.kind.isAutoRuleEligible })
    }
}
