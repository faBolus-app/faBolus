import Testing
import Foundation
@testable import faBolus

/// P15 E7 — the CGM-fallback credential sources must never trap on unvalidated user input. Before the
/// fix, a malformed `nightscout.url` or `librelinkup.region` force-unwrapped a nil `URL`/`URLComponents`
/// and crashed — and not only from "Save and test": the same code runs on every background poll. These
/// pin that a bad value throws a typed error instead.
@MainActor
@Suite(.serialized) struct CgmSourceValidationTests {

    /// A malformed Nightscout URL throws `SourceError.invalidConfig`, never traps. The `poll()` guard
    /// fires before any network call, so this is deterministic and offline.
    @Test func nightscoutMalformedURLThrowsInsteadOfTrapping() async {
        let original = GlucoseSourceConfig.string("nightscout.url")
        defer { GlucoseSourceConfig.set(original, "nightscout.url") }

        for bad in ["not a url", "ht tp://host", "://nohost", "ftp://host", "  ", "javascript:alert(1)"] {
            GlucoseSourceConfig.set(bad, "nightscout.url")
            await #expect(throws: SourceError.self, "\(bad.debugDescription) must throw, not trap") {
                _ = try await NightscoutSource().poll()
            }
        }
    }

    /// D-13: `NightscoutBackfill` (treatments/carbs/insulin) shares the user-entered `nightscout.url`
    /// but used to force-unwrap `URLComponents(string:)!` / `comps.url!`, trapping on a malformed URL
    /// that `NightscoutSource` (glucose) already validates. Pins that the treatments-URL builder now
    /// throws instead of trapping — and still builds a well-formed URL correctly. Offline, no network.
    @Test func nightscoutBackfillMalformedURLThrowsInsteadOfTrapping() throws {
        for bad in ["not a url", "ht tp://host", "://nohost", "ftp://host", "  ", "javascript:alert(1)"] {
            #expect(throws: SourceError.self, "\(bad.debugDescription) must throw, not trap") {
                _ = try NightscoutBackfill.treatmentsURL(root: bad, token: nil, days: 30)
            }
        }
        // A well-formed URL still builds correctly (scheme/host/path preserved).
        let url = try NightscoutBackfill.treatmentsURL(root: "https://ns.example.com", token: "tok", days: 30)
        #expect(url.scheme == "https")
        #expect(url.host == "ns.example.com")
        #expect(url.path == "/api/v1/treatments.json")
    }

    /// E7 (A3): the "Test" button exercises ONLY the currently-selected fallback source — the one the app
    /// will actually use — not the old whole-set sweep. Empty when no fallback has been chosen yet (button
    /// disabled). This pins the selected-only contract independent of the SwiftUI view.
    @Test func testExercisesOnlyTheSelectedSource() {
        #expect(CgmCredentialsView.sourcesToTest(selectedId: "nightscout") == ["nightscout"])
        #expect(CgmCredentialsView.sourcesToTest(selectedId: "dexcom-g7-ble") == ["dexcom-g7-ble"])
        #expect(CgmCredentialsView.sourcesToTest(selectedId: nil).isEmpty)
        #expect(CgmCredentialsView.sourcesToTest(selectedId: "").isEmpty)
    }
}
