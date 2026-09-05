import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// iOS widgets must age glucose off the sample timestamp under the phone's published freshness policy,
/// including future-skew. A missing policy must not silently fall back to a 6-minute hardcode.
@MainActor
@Suite(.serialized) struct WidgetStalenessTests {
    private func mins(_ m: Double, after base: Date) -> Date { base.addingTimeInterval(m * 60) }

    @Test func snapshotAgesFreshThenStaleThenHiddenAtTheEntryDate() {
        let taken = Date(timeIntervalSince1970: 1_000_000)
        // Grey (stale) at 5 min; hide ("--") at 10 min.
        let snap = WidgetSnapshot(
            glucose: 120, glucoseDate: taken,
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
        let entry = Date(timeIntervalSince1970: 1_000_000)  // the widget entry's render date

        // Dated 30 min AHEAD of the entry date — far beyond the 5-min skew tolerance.
        let ahead = WidgetSnapshot(
            glucose: 120, glucoseDate: mins(30, after: entry),
            staleAfterSec: 5 * 60, hideAfterSec: 10 * 60)
        #expect(ahead.isStale(asOf: entry))  // never presented as the live value
        #expect(!ahead.isHidden(asOf: entry))  // stale is shown greyed, not hidden-as-"--"

        // A few seconds ahead is within the skew tolerance — ordinary jitter, unaffected (still fresh).
        let jitter = WidgetSnapshot(
            glucose: 120, glucoseDate: entry.addingTimeInterval(5),
            staleAfterSec: 5 * 60, hideAfterSec: 10 * 60)
        #expect(!jitter.isStale(asOf: entry))
        #expect(!jitter.isHidden(asOf: entry))
    }

    /// The wall-clock path — `isStale(asOf:)` evaluated against the REAL clock (unlike
    /// `futureDatedSnapshotIsStaleAtTheEntryDate`'s fixed entry date) — must apply the same
    /// future-skew guard, plus a drift guard pinning the widget's mirrored tolerance equal to the
    /// canonical `GlucoseFreshness.futureSkewTolerance` (the widget target can't link faBolusCore).
    @Test func wallClockStalenessGuardsFutureDatedAndMirrorsCanonical() {
        let now = Date()
        let ahead = WidgetSnapshot(
            glucose: 120, glucoseDate: now.addingTimeInterval(30 * 60),
            staleAfterSec: 5 * 60, hideAfterSec: 10 * 60)
        #expect(ahead.isStale(asOf: now))  // future-dated beyond skew → stale, never the live value

        let jitter = WidgetSnapshot(
            glucose: 120, glucoseDate: now.addingTimeInterval(5),
            staleAfterSec: 5 * 60, hideAfterSec: 10 * 60)
        #expect(!jitter.isStale(asOf: now))  // within skew → unaffected

        // Drift guard: the mirror must equal the canonical tolerance (this target links both).
        #expect(WidgetSnapshot.futureSkewTolerance == GlucoseFreshness.futureSkewTolerance)
    }

    @Test func iOSPublisherCarriesThePhoneFreshnessPolicyOntoTheSnapshot() {
        // The defect: the iOS publisher built the snapshot WITHOUT the policy, so `staleAfterSec` /
        // `hideAfterSec` were nil and every widget silently used the 6-min hardcode. `makeSnapshot` is
        // the pure builder `publish` uses; test it directly (deterministic — no shared App-Group store,
        // so no racing sibling `refresh()`→`publish()` can overwrite it).
        let snap = WidgetPublisher.makeSnapshot(
            MockBackend().snapshot, history: [],
            staleAfterSec: 7 * 60, hideAfterSec: 20 * 60)
        // Explicit Double literals — `7 * 60` alone binds as Int against the `TimeInterval?` field.
        #expect(snap.staleAfterSec == 420.0)  // was nil (silent 6-min fallback)
        #expect(snap.hideAfterSec == 1200.0)
    }
}
