import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that the Nightscout stub never fetches, uploads, or persists high-water marks, and that
/// `maybeBackfillNightscout` stays deleted from AppModel. A half-live Nightscout path would put network I/O and UserDefaults dose markers back on main.
@MainActor
@Suite(.serialized) struct NightscoutStubInertnessTests {

    /// `NightscoutBackfill.fetch()` always returns nil — any remaining caller must exit immediately with no work.
    @Test func backfillFetchAlwaysReturnsNil() async {
        let result = await NightscoutBackfill.fetch()
        #expect(result == nil)
        // Repeated calls stay nil — not a first-call-only fluke.
        let again = await NightscoutBackfill.fetch(days: 7)
        #expect(again == nil)
    }

    /// `NightscoutUploader.shared` is a stable singleton so the remaining `sync(...)` call site always hits one object.
    @Test func sharedIsAStableSingleton() {
        let a = NightscoutUploader.shared
        let b = NightscoutUploader.shared
        #expect(a === b)
    }

    /// `sync(...)` is an inert no-op: it never persists the high-water-mark keys the real uploader used.
    @Test func syncIsAnInertNoOpThatNeverPersistsAnything() {
        let d = UserDefaults.standard
        for key in ["ns.lastEntryMs", "ns.lastBolusEpoch", "ns.lastStatus"] {
            d.removeObject(forKey: key)
        }

        var snapshot = PumpSnapshot()
        snapshot.glucose = 120
        let glucose = [GlucoseReading(date: Date(), mgdl: 120)]
        let boluses = [BolusMarker(date: Date(), units: 1.5)]

        // Exercised as a plain synchronous call — no `try`, no `await`.
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

    // MARK: - maybeBackfillNightscout stays deleted

    /// Source-level proof that `maybeBackfillNightscout()` is gone from AppModel, not merely renamed or re-gated.
    @Test func maybeBackfillNightscoutIsAbsentFromAppModel() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
        let appModelURL = repoRoot.appendingPathComponent("ios/faBolus/Data/AppModel.swift")
        let source = try String(contentsOf: appModelURL, encoding: .utf8)
        #expect(source.count > 200, "AppModel.swift resolved implausibly short — path resolution likely broke")

        // Declaration-SHAPED patterns, not bare substrings — the deletion's own explanatory comment
        // (a few lines above this test's target, in AppModel.swift) legitimately NAMES both deleted
        // symbols in prose to document what was removed and why; a bare `source.contains("lastNSBackfill")`
        // would false-positive on that comment. Matching the exact declaration shape sidesteps that.
        let deletedDeclarations = ["func maybeBackfillNightscout(", "var lastNSBackfill"]
        for declaration in deletedDeclarations {
            #expect(!source.contains(declaration),
                    "D4-07 violated — '\(declaration)' still present in AppModel.swift; the vestigial Nightscout backfill must be DELETED, not merely gated")
        }

        // The remaining `NightscoutUploader.shared.sync(...)` call site is the inert stub, not a backfill — confirm it is still present so this test does not silently start asserting something else.
        #expect(source.contains("NightscoutUploader.shared.sync("),
                "NightscoutUploader.shared.sync(...) call site unexpectedly missing — see the D4-07 rationale for why it stays")
    }
}
