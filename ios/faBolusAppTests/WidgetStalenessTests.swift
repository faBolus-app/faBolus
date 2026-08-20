import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P10 (defect group A) — the iOS widgets must age glucose off the reading's OWN sample timestamp,
/// under the phone's published freshness policy, exactly like the Mac widget (the reference impl).
/// Pins two halves of the iOS staleness defect:
///  1. the pure fresh → stale → hidden transitions the crossing-timeline entries and the views key off
///     (evaluated at the entry's date, since a widget renders ahead of time), and
///  2. that the iOS publisher now actually PUBLISHES the policy — the defect was that it left
///     `staleAfterSec`/`hideAfterSec` nil, so every iOS widget silently fell back to the 6-min hardcode
///     regardless of the user's Settings value.
@MainActor
@Suite(.serialized) struct WidgetStalenessTests {
    private func mins(_ m: Double, after base: Date) -> Date { base.addingTimeInterval(m * 60) }

    @Test func snapshotAgesFreshThenStaleThenHiddenAtTheEntryDate() {
        let taken = Date(timeIntervalSince1970: 1_000_000)
        // Grey (stale) at 5 min; hide ("--") at 10 min.
        let snap = WidgetSnapshot(glucose: 120, glucoseDate: taken,
                                  staleAfterSec: 5 * 60, hideAfterSec: 10 * 60)
        // Fresh: shown normally.
        #expect(!snap.isStale(asOf: mins(4, after: taken)))
        #expect(!snap.isHidden(asOf: mins(4, after: taken)))
        // Stale: greyed but still shown (not yet hidden).
        #expect(snap.isStale(asOf: mins(6, after: taken)))
        #expect(!snap.isHidden(asOf: mins(6, after: taken)))
        // Past the hide delay: not shown ("--").
        #expect(snap.isHidden(asOf: mins(11, after: taken)))
    }

    /// Loop-comms audit fix #1 (display half). The shared `GlucoseFreshness` policy treats a reading
    /// dated more than `futureSkewTolerance` (5 min) in the FUTURE as stale — a source with a fast
    /// clock stamps readings ahead of `now`, giving negative elapsed time that otherwise reads "fresh"
    /// forever. `WidgetSnapshot` doesn't delegate (its target can't link faBolusCore), so it carries
    /// the same guard; this pins the widget half of that guarantee against the widget entry's date.
    /// `CrossSurfaceStalenessTests.futureDatedSampleRendersStaleBeyondClockSkew` covers the other surfaces.
    @Test func futureDatedSnapshotIsStaleAtTheEntryDate() {
        let entry = Date(timeIntervalSince1970: 1_000_000)   // the widget entry's render date

        // Dated 30 min AHEAD of the entry date — far beyond the 5-min skew tolerance.
        let ahead = WidgetSnapshot(glucose: 120, glucoseDate: mins(30, after: entry),
                                   staleAfterSec: 5 * 60, hideAfterSec: 10 * 60)
        #expect(ahead.isStale(asOf: entry))       // never presented as the live value
        #expect(!ahead.isHidden(asOf: entry))     // stale is shown greyed, not hidden-as-"--"

        // A few seconds ahead is within the skew tolerance — ordinary jitter, unaffected (still fresh).
        let jitter = WidgetSnapshot(glucose: 120, glucoseDate: entry.addingTimeInterval(5),
                                    staleAfterSec: 5 * 60, hideAfterSec: 10 * 60)
        #expect(!jitter.isStale(asOf: entry))
        #expect(!jitter.isHidden(asOf: entry))
    }

    /// The wall-clock path (`isGlucoseStale` / `displayGlucose`, used by the complication) must apply
    /// the same future-skew guard, plus a drift guard pinning the widget's mirrored tolerance equal to
    /// the canonical `GlucoseFreshness.futureSkewTolerance` (the widget target can't link faBolusCore).
    @Test func wallClockStalenessGuardsFutureDatedAndMirrorsCanonical() {
        // Relative to the real wall clock, since `isGlucoseStale` evaluates against `Date()`.
        let ahead = WidgetSnapshot(glucose: 120, glucoseDate: Date().addingTimeInterval(30 * 60))
        #expect(ahead.isGlucoseStale)             // future-dated beyond skew → stale
        #expect(ahead.displayGlucose == "--")     // and never rendered as the live number

        let jitter = WidgetSnapshot(glucose: 120, glucoseDate: Date().addingTimeInterval(5))
        #expect(!jitter.isGlucoseStale)           // within skew → unaffected
        #expect(jitter.displayGlucose == "120")

        // Drift guard: the mirror must equal the canonical tolerance (this target links both).
        #expect(WidgetSnapshot.futureSkewTolerance == GlucoseFreshness.futureSkewTolerance)
    }

    @Test func iOSPublisherCarriesThePhoneFreshnessPolicyOntoTheSnapshot() {
        // The defect: the iOS publisher built the snapshot WITHOUT the policy, so `staleAfterSec` /
        // `hideAfterSec` were nil and every widget silently used the 6-min hardcode. `makeSnapshot` is
        // the pure builder `publish` uses; test it directly (deterministic — no shared App-Group store,
        // so no racing sibling `refresh()`→`publish()` can overwrite it).
        let snap = WidgetPublisher.makeSnapshot(MockBackend().snapshot, history: [], alerts: [],
                                                staleAfterSec: 7 * 60, hideAfterSec: 20 * 60)
        // Explicit Double literals — `7 * 60` alone binds as Int against the `TimeInterval?` field.
        #expect(snap.staleAfterSec == 420.0)   // was nil before P10 (silent 6-min fallback)
        #expect(snap.hideAfterSec == 1200.0)
    }

    // MARK: - Phase 09.9-04 (D-05): WidgetSnapshot.cartridgeReady

    /// WR-04 (debug pump-pairing-loop-api25, deep review): `makeSnapshot` now maps the Guardrail-B tri-state
    /// — a positive widget "ready" is presented ONLY for a CONFIRMED `.ready` op-20 reply, never the
    /// fail-open default. A CONFIRMED loading state maps to not-ready; an UNKNOWN/auto-excluded state maps
    /// to the non-positive `false` ("omit the positive badge" — the Bool can't carry a third state), so a
    /// state that was never read is never shown as a positive "ready". (Full WR-04 coverage — widget + the
    /// `Bool?` remote wire — lives in `CartridgeReadinessRemotePresentationTests`.)
    @Test func makeSnapshotMapsCartridgeReadyFromTheConfirmedTriState() {
        var pump = MockBackend().snapshot
        pump.cartridgeLoadState = 6                 // idle
        pump.cartridgeLoadStateConfirmed = true     // a real op-20 reply → confirmed ready
        let ready = WidgetPublisher.makeSnapshot(pump, history: [], alerts: [],
                                                 staleAfterSec: 5 * 60, hideAfterSec: nil)
        #expect(ready.cartridgeReady == true)

        pump.cartridgeLoadState = 1                 // LOAD_CARTRIDGE (confirmed loading) ⇒ not ready
        let notReady = WidgetPublisher.makeSnapshot(pump, history: [], alerts: [],
                                                    staleAfterSec: 5 * 60, hideAfterSec: nil)
        #expect(notReady.cartridgeReady == false)

        pump.cartridgeLoadState = 6
        pump.cartridgeLoadStateConfirmed = false    // never read / op-20 auto-excluded ⇒ UNKNOWN
        let unknown = WidgetPublisher.makeSnapshot(pump, history: [], alerts: [],
                                                   staleAfterSec: 5 * 60, hideAfterSec: nil)
        #expect(unknown.cartridgeReady == false,
                "an unknown cartridge must not present a fail-open 'ready' on the widget (WR-04)")
    }

    /// A legacy App-Group payload written before this field existed decodes with `cartridgeReady ==
    /// true` (the safe "ready" default) — an older widget-extension binary must never render a false
    /// "cartridge not ready" scare from a missing key. An explicit `false` round-trips unchanged.
    @Test func cartridgeReadyDecodesToSafeDefaultOnLegacyPayloadAndRoundTripsExplicitFalse() throws {
        // Simulate a pre-Phase-09.9-04 payload: encode a snapshot, then strip the key before decoding.
        let snap = WidgetSnapshot(glucose: 120)
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snap)) as! [String: Any]
        obj.removeValue(forKey: "cartridgeReady")
        let legacyData = try JSONSerialization.data(withJSONObject: obj)
        let decodedLegacy = try JSONDecoder().decode(WidgetSnapshot.self, from: legacyData)
        #expect(decodedLegacy.cartridgeReady == true)

        // Explicit false round-trips.
        var notReady = WidgetSnapshot(glucose: 120)
        notReady.cartridgeReady = false
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(notReady))
        #expect(decoded.cartridgeReady == false)
    }

    // MARK: - Phase 09.26-05 (D-04): every full-bleed presentation shares ONE staleness gate

    /// 09.26-05-PLAN.md Task 2: "reuse the existing `context.arrow` / `glucoseColor(stale:)`
    /// extension verbatim, do NOT add a second staleness rule." The new DI-expanded full-bleed
    /// distribution (09.26-05) and the always-on treatment both read `GlucoseLiveActivityManager
    /// .makeContent`'s baked `trendArrow`/staleDate — this pins that the bake is IDENTICAL for
    /// "classic" and "fullBleed" on the SAME snapshot, guarding against a future edit that
    /// accidentally special-cases full-bleed's own staleness computation instead of reusing the one
    /// gate every presentation (Lock Screen, DI expanded, always-on) renders through.
    @Test func stalenessGateIsIdenticalAcrossBothLiveActivityStylesForTheSameSnapshot() {
        let previousStyle = WidgetStore.liveActivityStyle
        defer { WidgetStore.liveActivityStyle = previousStyle }

        let now = Date(timeIntervalSince1970: 5_000_000)
        // Sampled 10 min ago, stale after 5 min — squarely stale-as-of-now (C8: never synthesized).
        let stale = WidgetSnapshot(glucose: 140, glucoseDate: now.addingTimeInterval(-600),
                                   trendArrow: "↑", staleAfterSec: 5 * 60)

        WidgetStore.liveActivityStyle = "fullBleed"
        let (fullBleedState, fullBleedStaleDate, _) =
            GlucoseLiveActivityManager.makeContent(from: stale, now: now)

        WidgetStore.liveActivityStyle = "classic"
        let (classicState, classicStaleDate, _) =
            GlucoseLiveActivityManager.makeContent(from: stale, now: now)

        // Both styles drop the arrow identically — never a synthesized fallback in either style.
        #expect(fullBleedState.trendArrow == "")
        #expect(classicState.trendArrow == "")
        // Both styles compute the SAME staleDate (sample date + threshold) — style is a rendering
        // choice, never a second freshness policy.
        #expect(fullBleedStaleDate == classicStaleDate)
        #expect(fullBleedState.glucose == classicState.glucose)
        #expect(fullBleedState.liveActivityStyle == "fullBleed")
        #expect(classicState.liveActivityStyle == "classic")
    }

    /// The fresh case, mirrored: both styles carry the SAME arrow verbatim (never re-derived per
    /// style) while the reading is still within the stale threshold.
    @Test func freshTrendArrowCarriedIdenticallyAcrossBothLiveActivityStyles() {
        let previousStyle = WidgetStore.liveActivityStyle
        defer { WidgetStore.liveActivityStyle = previousStyle }

        let now = Date(timeIntervalSince1970: 6_000_000)
        let fresh = WidgetSnapshot(glucose: 110, glucoseDate: now.addingTimeInterval(-30),
                                   trendArrow: "↗", staleAfterSec: 5 * 60)

        WidgetStore.liveActivityStyle = "fullBleed"
        let (fullBleedState, _, _) = GlucoseLiveActivityManager.makeContent(from: fresh, now: now)
        WidgetStore.liveActivityStyle = "classic"
        let (classicState, _, _) = GlucoseLiveActivityManager.makeContent(from: fresh, now: now)

        #expect(fullBleedState.trendArrow == "↗")
        #expect(classicState.trendArrow == "↗")
    }
}
