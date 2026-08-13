import Foundation
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
        let state = FaBolusGlucoseAttributes.ContentState(
            glucose: snap.glucose,
            glucoseDate: snap.glucoseDate,
            trendArrow: stale ? "" : snap.trendArrow,             // C8 — never synthesize a trend
            recentPoints: Array(snap.recentPoints.suffix(24)),    // tighter cap than the widget's 48
            displayUnitToken: snap.displayUnit                    // D-09 — carried verbatim, no inline conversion
        )
        let staleDate = (snap.glucoseDate ?? now).addingTimeInterval(snap.staleAfterSec ?? 360)
        return (state: state, staleDate: staleDate, timestamp: snap.glucoseDate)
    }

    /// Start-vs-update-vs-re-arm-vs-gate decision — PURE, makes NO ActivityKit calls, so it's
    /// unit-testable off an injected activity state (Task 3, `LiveActivityManagerTests`). `enabled`
    /// is `ActivityAuthorizationInfo().areActivitiesEnabled` in this tracer; 05-04 composes it with
    /// the opt-in `AppSettings.shared.liveActivityEnabled` (D-15) — that property does not exist yet
    /// and must NOT be referenced here.
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

    /// I/O half — called from `WidgetPublisher.publish(...)` (D-03), the single BLE-driven choke
    /// point. Reads `Activity<FaBolusGlucoseAttributes>.activities` synchronously (a plain static
    /// property, not async) to decide, then performs the ActivityKit side effect in a detached
    /// `Task` so the hot `@MainActor` publish path never blocks on it — Loop's cooperative-pool
    /// discipline (`LiveActivityManager.swift`'s `getInsulinOnBoard()` deadlock note): never bridge
    /// async→sync by blocking this thread.
    @MainActor
    static func update(from snap: WidgetSnapshot) {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
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

        Task {
            // endUnknownActivities() (Loop) — defend against a duplicate Activity somehow existing
            // (e.g. across a relaunch) rather than assuming exactly one.
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
    }
}
