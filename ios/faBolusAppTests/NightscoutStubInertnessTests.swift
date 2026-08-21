import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// D-04 (HEALTH-02) — proves the `main`-only Nightscout stub (`NightscoutStub.swift`) is truly inert:
/// `NightscoutBackfill.fetch()` never performs a fetch (always nil), and `NightscoutUploader.shared.
/// sync(...)` never touches history/dose state or persists anything. This is the load-bearing proof
/// that `git rm`-ing the 3 real Nightscout files (which DID touch UserDefaults high-water marks —
/// `ns.lastEntryMs`/`ns.lastBolusEpoch`/`ns.lastStatus` — and performed real network I/O) left behind
/// a genuine no-op, not a silently-broken half-implementation.
@MainActor
@Suite(.serialized) struct NightscoutStubInertnessTests {

    /// `NightscoutBackfill.fetch()` always returns nil — the frozen `AppModel.maybeBackfillNightscout()`
    /// closure's `guard let r = await NightscoutBackfill.fetch() else { return }` must exit immediately
    /// on every call, on `main`, with no exception.
    @Test func backfillFetchAlwaysReturnsNil() async {
        let result = await NightscoutBackfill.fetch()
        #expect(result == nil)
        // Repeated calls stay nil — not a first-call-only fluke.
        let again = await NightscoutBackfill.fetch(days: 7)
        #expect(again == nil)
    }

    /// `NightscoutUploader.shared` is a stable singleton — the same instance every access, exactly as
    /// the real implementation's `static let shared` guarantees, so the frozen call site
    /// `AppModel.swift:1799` (`NightscoutUploader.shared.sync(...)`) keeps referencing one object.
    @Test func sharedIsAStableSingleton() {
        let a = NightscoutUploader.shared
        let b = NightscoutUploader.shared
        #expect(a === b)
    }

    /// `sync(...)` is an inert no-op: calling it exactly as `AppModel.swift:1799` does (a plain,
    /// synchronous, non-throwing call — proven at compile time by the absence of `try`/`await` below)
    /// never persists any of the high-water-mark keys the REAL uploader used
    /// (`ns.lastEntryMs`/`ns.lastBolusEpoch`/`ns.lastStatus`), proving it never ran any upload logic.
    @Test func syncIsAnInertNoOpThatNeverPersistsAnything() {
        let d = UserDefaults.standard
        for key in ["ns.lastEntryMs", "ns.lastBolusEpoch", "ns.lastStatus"] {
            d.removeObject(forKey: key)
        }

        var snapshot = PumpSnapshot()
        snapshot.glucose = 120
        let glucose = [GlucoseReading(date: Date(), mgdl: 120)]
        let boluses = [BolusMarker(date: Date(), units: 1.5)]

        // Exercised exactly as AppModel.swift:1799 does — no `try`, no `await`.
        NightscoutUploader.shared.sync(snapshot: snapshot, glucose: glucose, boluses: boluses)

        for key in ["ns.lastEntryMs", "ns.lastBolusEpoch", "ns.lastStatus"] {
            #expect(d.object(forKey: key) == nil,
                    "\(key) must stay unset — the stub must never persist an upload high-water mark")
        }

        // Calling it again is equally inert (not a one-shot no-op that then does real work).
        NightscoutUploader.shared.sync(snapshot: snapshot, glucose: glucose, boluses: boluses)
        for key in ["ns.lastEntryMs", "ns.lastBolusEpoch", "ns.lastStatus"] {
            #expect(d.object(forKey: key) == nil)
        }
    }
}
