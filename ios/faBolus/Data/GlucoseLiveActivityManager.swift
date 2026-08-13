import Foundation
import faBolusCore
// ActivityKit's `Activity<Attributes>` (a `class`) isn't marked `Sendable` in its public interface,
// even though Apple's own docs describe it as safe to call from any context — Apple hasn't audited
// this framework for Swift 6 strict concurrency yet. `@preconcurrency` downgrades the "sending a
// non-Sendable instance across an actor boundary" diagnostic to a warning (matching pre-Swift-6
// behavior) instead of a hard build error, so `update(from:)` below can bridge its @MainActor
// publish-path caller to the detached `Task` that performs the actual ActivityKit request/update/end.
@preconcurrency import ActivityKit

// Portions adapted from Loop (github.com/LoopKit/Loop), MIT License.
// Copyright (c) 2015 Nathan Racklyeft. Copyright (c) 2016 LoopKit Authors.
//
// Adopts Loop's app-driven `Activity.update`/re-arm structure (see `LiveActivityManager.swift`'s
// `needsRecreation()`/`endActivity()`/`endUnknownActivities()` + cooperative-pool-safe async bridge)
// — NOT Loop's push-token flow (faBolus never uses APNs, D-04). See 05-REFERENCE-COMPARISON.md §5.

/// App-target Live Activity lifecycle for the glucose LA (D-03) — driven from the existing
/// `WidgetPublisher.publish(...)` BLE choke point, never a wall-clock timer (D-05).
enum GlucoseLiveActivityManager {
    /// Pure content builder — no ActivityKit I/O, no WidgetKit — so the staleDate math, the
    /// no-synthesized-trend rule (C8), and the mmol-token carry (D-09) are unit-testable without a
    /// running Activity. Mirrors `WidgetPublisher.makeSnapshot`'s pure/I-O split (`WidgetPublisher
    /// .swift:13-16`): this is the pure half; the `@MainActor` ActivityKit I/O half is
    /// `update(from:)` below.
    ///
    /// - `staleDate` = the SAMPLE date (`snap.glucoseDate`) + the published stale threshold — never
    ///   `now + fixed` (Loop's own `Date.now.addingTimeInterval(.hours(1))` is exactly the bug this
    ///   rule forbids; D-06 / 05-RESEARCH.md Pitfall #3).
    /// - `timestamp` = the SAMPLE date, so `Activity.update(timestamp:)`'s monotonic guarantee
    ///   actually protects against an older reading overwriting a newer one (D-06).
    static func makeContent(
        from snap: WidgetSnapshot, now: Date
    ) -> (state: FaBolusGlucoseAttributes.ContentState, staleDate: Date, timestamp: Date?) {
        let stale = snap.isStale(asOf: now)
        // Phase 5 pump surfaces (D-17, 05-02) — the two APP-COMPUTED staleness flags. Computed HERE
        // (the app target links faBolusCore) so the extension never re-derives a freshness threshold.
        //
        // iobStale mirrors CalcInputFreshness.iobPresentation exactly: a nil stamp is `.hidden`, not
        // `.stale`, from that API's own perspective — but the LA still must never show a numberless/
        // unstamped IOB as current, so `iobDate == nil` is folded in explicitly as its own `true`
        // (matching the HUD's `StatusPillsView.pillFor("iob")`, which greys off the SAME presentation
        // check, and the plan's own stated rule).
        let iobStale = snap.iobDate == nil
            || CalcInputFreshness.iobPresentation(of: snap.iobDate, now: now) == .stale
        // The dateless cluster (reservoir/battery/basal/Control-IQ) has no per-field stamp, so it
        // greys off LINK freshness instead: down, or the snapshot itself older than the phone's
        // published last-sync threshold (reusing `staleAfterSec` rather than a second hardcode, so it
        // tracks the user's own freshness setting).
        let pumpLinkStale = !snap.connected || now.timeIntervalSince(snap.updatedAt) > (snap.staleAfterSec ?? 360)
        // D-15/D-17a (05-04) — read the App-Group mirror the SwiftUI views can't access directly
        // (pump-surface research §2b); fall back to the full LA vocabulary when nothing has synced
        // yet (a legacy install, or before `AppSettings.syncWidgetConfig()` has ever run) rather than
        // baking in an empty selection that would render the empty-selection fallback for no reason.
        let selection = WidgetStore.liveActivityFields ?? LAFieldVocabulary.all
        let state = FaBolusGlucoseAttributes.ContentState(
            glucose: snap.glucose,
            glucoseDate: snap.glucoseDate,
            trendArrow: stale ? "" : snap.trendArrow,             // C8 — never synthesize a trend
            recentPoints: Array(snap.recentPoints.suffix(24)),    // tighter cap than the widget's 48
            displayUnitToken: snap.displayUnit,                   // D-09 — carried verbatim, no inline conversion
            iobUnits: snap.iobUnits,
            iobDate: snap.iobDate,
            reservoirUnits: snap.reservoirUnits,
            batteryPercent: snap.batteryPercent,
            basalRateUnitsPerHour: snap.basalRateUnitsPerHour,    // effective U/hr — never a synthesized temp-rate %
            deliverySuspended: snap.deliverySuspended,
            controlIQMode: snap.controlIQMode,
            controlIQEnabled: snap.controlIQEnabled,
            connected: snap.connected,
            updatedAt: snap.updatedAt,
            iobStale: iobStale,
            pumpLinkStale: pumpLinkStale,
            selectedFields: selection,
            hasSnoozeEligibleAlert: snap.hasSnoozeEligibleAlert
        )
        let staleDate = (snap.glucoseDate ?? now).addingTimeInterval(snap.staleAfterSec ?? 360)
        return (state: state, staleDate: staleDate, timestamp: snap.glucoseDate)
    }

    /// Start-vs-update-vs-re-arm-vs-gate decision — PURE, makes NO ActivityKit calls, so it's
    /// unit-testable off an injected activity state (Task 3, `LiveActivityManagerTests`). `enabled`
    /// is the COMPOSED gate from `gateEnabled(optIn:authorized:)` below (D-15) as of 05-04 — the
    /// tracer's own `enabled` was `ActivityAuthorizationInfo().areActivitiesEnabled` alone.
    enum LiveActivityAction: Equatable { case start, update, end, none }

    static func decideAction(
        enabled: Bool, hasRunningActivity: Bool, runningIsStaleOrEnded: Bool
    ) -> LiveActivityAction {
        guard enabled else { return hasRunningActivity ? .end : .none }
        // No activity running, or the running one is .ended/.dismissed/.stale → (re-)request one on
        // this reading (D-05 — reactive re-arm, no push-to-start, no wall-clock timer).
        if !hasRunningActivity || runningIsStaleOrEnded { return .start }
        return .update
    }

    /// The D-15 opt-in gate, PURE and unit-testable off two injected booleans (no `ActivityKit`, no
    /// `AppSettings`) — the property the 05-01 tracer deliberately deferred ("the opt-in
    /// `AppSettings.shared.liveActivityEnabled` AND-gate is ADDED in 05-04"). `update(from:)` feeds
    /// this composed result into `decideAction(enabled:...)` as its `enabled` argument.
    static func gateEnabled(optIn: Bool, authorized: Bool) -> Bool { optIn && authorized }

    /// WR-03 gap closure (05-06) — serializes overlapping `update(from:)` invocations. Chains each
    /// call onto whatever the PREVIOUS call's work was doing, so two calls arriving in close
    /// succession (plausible: `WidgetPublisher.publish` is reachable from `AppModel.refresh()`, which
    /// itself can fire from a BLE notification callback, a manual pull-to-refresh, AND the ~20s
    /// arbiter timer) never both read "no running activity" before either has actually run its
    /// `Activity.request(...)` — the SAME race the pre-existing `endUnknownActivities()` cleanup loop
    /// only papered over after the fact (a real, if self-correcting, transient double-request +
    /// flicker). `update(from:)` itself stays synchronous/non-blocking for its @MainActor caller — it
    /// only enqueues; the awaiting happens inside the chained `Task`.
    @MainActor private static var inFlight: Task<Void, Never>?

    /// I/O half — called from `WidgetPublisher.publish(...)` (D-03), the single BLE-driven choke
    /// point. Enqueues `performUpdate(from:)` behind whatever is already in flight (WR-03) so the
    /// decide+act sequence for a burst of calls runs one at a time, never overlapping.
    @MainActor
    static func update(from snap: WidgetSnapshot) {
        let previous = inFlight
        inFlight = Task {
            _ = await previous?.value
            await performUpdate(from: snap)
        }
    }

    /// The actual decide+act sequence, run to completion by exactly one `update(from:)` call at a
    /// time (WR-03's serialization) — otherwise UNCHANGED from the pre-05-06 body of `update(from:)`.
    /// Reads `Activity<FaBolusGlucoseAttributes>.activities` synchronously (a plain static property,
    /// not async) to decide, then performs the ActivityKit side effect — Loop's cooperative-pool
    /// discipline (`LiveActivityManager.swift`'s `getInsulinOnBoard()` deadlock note): never bridge
    /// async→sync by blocking this thread.
    @MainActor
    private static func performUpdate(from snap: WidgetSnapshot) async {
        // D-15 (05-04) — the composed opt-in gate: the tracer's `areActivitiesEnabled` alone is no
        // longer sufficient; the app-level opt-in (default OFF, AppSettings.swift) must ALSO be true.
        let enabled = gateEnabled(
            optIn: AppSettings.shared.liveActivityEnabled,
            authorized: ActivityAuthorizationInfo().areActivitiesEnabled)
        let running = Activity<FaBolusGlucoseAttributes>.activities.first
        let runningIsStaleOrEnded: Bool = switch running?.activityState {
        case .some(.ended), .some(.dismissed), .some(.stale), .none: true
        default: false
        }
        let action = decideAction(enabled: enabled, hasRunningActivity: running != nil,
                                   runningIsStaleOrEnded: runningIsStaleOrEnded)
        guard action != .none else { return }

        let (state, staleDate, timestamp) = makeContent(from: snap, now: Date())
        let content = ActivityContent(state: state, staleDate: staleDate)
        let keepId = running?.id

        // endUnknownActivities() (Loop) — defend against a duplicate Activity somehow existing (e.g.
        // across a relaunch) rather than assuming exactly one. With `update(from:)`'s calls now
        // serialized (WR-03), this is a belt-and-suspenders defense, not the primary race guard.
        for other in Activity<FaBolusGlucoseAttributes>.activities where other.id != keepId {
            await other.end(nil, dismissalPolicy: .immediate)
        }
        switch action {
        case .start:
            // Re-arm (D-05): end whatever this stale/ended instance still is, then request fresh.
            if let running { await running.end(nil, dismissalPolicy: .immediate) }
            _ = try? Activity.request(attributes: FaBolusGlucoseAttributes(), content: content, pushType: nil)
        case .update:
            // D-06 monotonicity — `timestamp:` is the SAMPLE date, never `Date()`. The
            // `timestamp:` overload needs iOS 17.2+ (D-11's floor is 17.0); 17.0/17.1 falls back
            // to the base `update(_:)` (no monotonic guard available at that OS level — a
            // disclosed, OS-imposed limitation, not a faBolus omission).
            if #available(iOS 17.2, *) {
                await running?.update(content, timestamp: timestamp ?? Date())
            } else {
                await running?.update(content)
            }
        case .end:
            await running?.end(nil, dismissalPolicy: .immediate)
        case .none:
            break
        }
    }

    /// D-15/D-17a (05-04) — forces an immediate LA refresh when the opt-in or field selection
    /// changes, so a Settings toggle applies at once rather than waiting for the next pump reading
    /// (pump-surface research §2b). Called from `AppSettings`'s `liveActivityEnabled`/
    /// `liveActivityFields` `didSet`. Re-runs the normal `update(from:)` path over the LAST published
    /// snapshot — there is nothing else to project; if nothing has ever been published yet, this is a
    /// harmless no-op (there is nothing to show regardless of the toggle).
    @MainActor
    static func refreshForSelectionChange() {
        guard let snap = WidgetStore.load() else { return }
        update(from: snap)
    }
}
