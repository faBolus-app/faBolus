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
///
/// **D4-07 (16-04, Phase 16 GO-1 Step 4) addition:** `AppModel.maybeBackfillNightscout()` — the ONE
/// caller of `NightscoutBackfill.fetch()` — was itself DELETED outright (not carved into a new file):
/// its guard (`GlucoseSourceConfig.string("nightscout.url") != nil`) could never be true on `main`
/// (no descriptor named `"nightscout"` remains in `GlucoseSourceRegistry.enabled`, and no UI writes
/// the `nightscout.url` config key), so the whole method body was unreachable dead code, distinct
/// from the merely-inert-but-reachable stub methods above. `maybeBackfillNightscoutIsAbsentFromAppModel`
/// below is the source-level zero-reference proof.
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
            #expect(
                d.object(forKey: key) == nil,
                "\(key) must stay unset — the stub must never persist an upload high-water mark")
        }

        // Calling it again is equally inert (not a one-shot no-op that then does real work).
        NightscoutUploader.shared.sync(snapshot: snapshot, glucose: glucose, boluses: boluses)
        for key in ["ns.lastEntryMs", "ns.lastBolusEpoch", "ns.lastStatus"] {
            #expect(d.object(forKey: key) == nil)
        }
    }

    // MARK: - D4-07 (16-04): zero-runtime-reference proof for the DELETED backfill

    /// Source-level proof that `AppModel.maybeBackfillNightscout()` — the vestigial-on-main backfill
    /// whose guard could never be true (no `"nightscout"` descriptor in `GlucoseSourceRegistry.enabled`,
    /// no UI writing `nightscout.url`) — is genuinely GONE from `AppModel.swift`, not merely renamed or
    /// re-gated. Mirrors `LiveActivityAbsenceGuardTests`'/`NudgeDeliveryBoundaryTests`' `#filePath`-rooted
    /// whole-file source scan + non-vacuous `!source.isEmpty` guard, so a path-resolution break fails
    /// loudly instead of passing vacuously.
    @Test func maybeBackfillNightscoutIsAbsentFromAppModel() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot =
            testFileURL
            .deletingLastPathComponent()  // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()  // → .../ios
            .deletingLastPathComponent()  // → repo root
        let appModelURL = repoRoot.appendingPathComponent("ios/faBolus/Data/AppModel.swift")
        let source = try String(contentsOf: appModelURL, encoding: .utf8)
        #expect(source.count > 200, "AppModel.swift resolved implausibly short — path resolution likely broke")

        // Declaration-SHAPED patterns, not bare substrings — the deletion's own explanatory comment
        // (a few lines above this test's target, in AppModel.swift) legitimately NAMES both deleted
        // symbols in prose to document what was removed and why; a bare `source.contains("lastNSBackfill")`
        // would false-positive on that comment. Matching the exact declaration shape sidesteps that.
        let deletedDeclarations = ["func maybeBackfillNightscout(", "var lastNSBackfill"]
        for declaration in deletedDeclarations {
            #expect(
                !source.contains(declaration),
                "D4-07 violated — '\(declaration)' still present in AppModel.swift; the vestigial Nightscout backfill must be DELETED, not merely gated"
            )
        }

        // The separate, unconditionally-reachable `NightscoutUploader.shared.sync(...)` call site is
        // NOT deleted (it does not meet the same zero-reference bar) — confirm it is still present so
        // this test does not silently start asserting something it was never meant to.
        #expect(
            source.contains("NightscoutUploader.shared.sync("),
            "NightscoutUploader.shared.sync(...) call site unexpectedly missing — see the D4-07 rationale for why it stays"
        )
    }
}
