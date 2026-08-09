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

    /// The LibreLinkUp regional-host builder accepts only a short token region, so a free-text settings
    /// value (or a garbled server redirect) can never build a host that traps `URL(string:)!`.
    @Test func libreRegionHostAcceptsOnlySafeTokens() {
        #expect(LibreLinkUpSource.regionHost("us") == "https://api-us.libreview.io")
        #expect(LibreLinkUpSource.regionHost("eu2") == "https://api-eu2.libreview.io")
        #expect(LibreLinkUpSource.regionHost("ap") == "https://api-ap.libreview.io")
        for bad in ["us east", "", "a", "eu/../x", "eu.libreview.io", "toolongregion", "US", "e u", "eu\n"] {
            #expect(LibreLinkUpSource.regionHost(bad) == nil, "\(bad.debugDescription) must be rejected")
        }
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
