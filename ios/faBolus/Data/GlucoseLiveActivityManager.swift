import Foundation
import ActivityKit

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
}
