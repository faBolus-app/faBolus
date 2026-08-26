import Foundation
import faBolusCore

/// Phase 16 GO-1 Step 2 (REMED-16, GO-1 §4.2, R4/R15/R33) — the pure presentation/formatting
/// mappers extracted from `AppModel`. Behavior-preserving: every mapper here is a straight move of
/// the original `AppModel` body, unchanged, so the user-visible failover badge / short source name
/// and the two pure gate predicates are byte-for-byte identical before and after the extraction.
///
/// **INV-C (no second source of pump truth).** `failoverBadge` takes the already-computed
/// `GlucoseProvenance` value IN and never reads `AppModel`'s `source`/snapshot live — `AppModel`'s
/// own `failoverBadge` computed property (the only place `glucoseProvenance` is read) supplies it.
/// `shouldPushStatus`/`snoozeGateAllows` are — as before the move — pure value-in/value-out
/// predicates with no `AppModel`/singleton/clock read of their own.
///
/// `failoverBadge` is `@MainActor` because `GlucoseSourceRegistry.descriptor(id:)` (its one
/// dependency) is itself `@MainActor` — every call site (`AppModel.failoverBadge`, itself a member
/// of the `@MainActor final class AppModel`) is already isolated, so this is not a behavior change.
/// `shortSourceName`/`shouldPushStatus`/`snoozeGateAllows` stay free of actor isolation, exactly as
/// they were on `AppModel` (`shouldPushStatus`/`snoozeGateAllows` were already `nonisolated static`
/// there — pure and independently unit-testable off any fixture, including from a plain synchronous
/// test function).
enum FailoverBadgePresenter {

    /// A short source name + human reason when the live glucose is coming from a **failover** source
    /// instead of the pump; `nil` when the pump feed is live (`provenance == .pump`). Moved verbatim
    /// from `AppModel.failoverBadge`'s body — value-in (`provenance`) / value-out, no live read.
    @MainActor
    static func failoverBadge(provenance: GlucoseProvenance) -> (name: String, reason: String)? {
        guard case let .failover(sourceID, reason) = provenance else { return nil }
        let full = GlucoseSourceRegistry.descriptor(id: sourceID)?.name ?? sourceID
        let name = shortSourceName(full)
        switch reason {
        case .pumpMissing: return (name, "Showing \(full) — the pump has no CGM reading.")
        case .pumpStale:   return (name, "Showing \(full) — the pump's CGM reading went stale.")
        }
    }

    /// A compact source name for the small "via …" failover badge — drops the parenthetical/qualifier
    /// so no source name overruns the ring (e.g. "Dexcom Share (cloud)" → "Dexcom Share",
    /// "Dexcom G7 / ONE+ (direct BLE)" → "Dexcom G7"). Moved verbatim from `AppModel.shortSourceName`.
    static func shortSourceName(_ full: String) -> String {
        var s = full
        for sep in [" (", " — ", " / "] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a status push is due (§5.4). Pushes immediately (bypassing the 15 s throttle) on a NEW
    /// glucose SAMPLE — identified by its source timestamp, so a fresh reading at an unchanged mg/dL
    /// still pushes (the old code compared the value only, so a repeated number silently didn't reach
    /// the remotes) — on any connection-state change (the watch sees the bolus start + the settle
    /// instantly), and continuously while a bolus is in progress; otherwise at most once per throttle
    /// window to spare phone + watch battery. Pure, so the cadence rule is unit-testable. Moved
    /// verbatim from `AppModel.shouldPushStatus` (was already `nonisolated static`).
    static func shouldPushStatus(newGlucose: Int?, newGlucoseDate: Date?,
                                  lastGlucose: Int?, lastGlucoseDate: Date?,
                                  newConnection: PumpConnectionState, lastConnection: PumpConnectionState?,
                                  secondsSinceLastPush: TimeInterval, throttle: TimeInterval = 15) -> Bool {
        let newSample = newGlucose != lastGlucose || newGlucoseDate != lastGlucoseDate
        let connChanged = newConnection != lastConnection
        let bolusing = newConnection == .bolusing
        return newSample || connChanged || bolusing || secondsSinceLastPush > throttle
    }

    /// WR-02 gap closure (05-06) — the SINGLE "can Snooze actually do anything right now" predicate,
    /// fed into `WidgetPublisher.publish`'s `hasSnoozeEligibleAlert` parameter (`WidgetSnapshot`).
    /// True only when there's at least one active alert AND none of them is `.alarm` (an `.alarm`
    /// blocks snoozing entirely — mirrors `AlertRuleEngine`'s own "never match alarms" rule). Pure —
    /// no `AppModel` state read beyond the alerts array handed in, so it's independently
    /// unit-testable off any `[PumpAlert]` fixture. Moved verbatim from `AppModel.snoozeGateAllows`
    /// (was already `nonisolated static`). Note: this predicate's original doc comment (still present
    /// verbatim in `AppModel.swift`'s history/D-03-tolerated exception) described a since-removed
    /// (FEAT-01) Live-Activity Snooze-button visibility/action-gate consumer; this file's version
    /// drops that stale reference rather than propagate it into a file `LiveActivityAbsenceGuardTests`
    /// does not tolerate as an exception.
    static func snoozeGateAllows(_ alerts: [PumpAlert]) -> Bool {
        !alerts.isEmpty && !alerts.contains(where: { !$0.kind.isAutoRuleEligible })
    }
}
