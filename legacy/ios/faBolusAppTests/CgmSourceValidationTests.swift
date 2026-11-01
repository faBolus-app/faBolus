import Testing
import Foundation
@testable import faBolus

/// The CGM-fallback credential sources must never trap on unvalidated user input. Before the fix, a
/// malformed `nightscout.url` or `librelinkup.region` force-unwrapped a nil `URL`/`URLComponents` and
/// crashed — and not only from "Save and test": the same code runs on every background poll. These pin
/// that a bad value throws a typed error instead.
@MainActor
@Suite(.serialized) struct CgmSourceValidationTests {

    // The Nightscout-specific malformed-URL guards (nightscoutMalformedURLThrowsInsteadOfTrapping,
    // nightscoutBackfillMalformedURLThrowsInsteadOfTrapping) were deleted here along with
    // `NightscoutSource`/`NightscoutBackfill.treatmentsURL`, which no longer exist on narrow `main` —
    // see dev/nightscout's REINTEGRATION.md. The entire attack surface they pinned (a user-entered
    // Nightscout URL) is removed, not relocated.

    /// The "Test" button exercises ONLY the currently-selected fallback source — the one the app will
    /// actually use — not the old whole-set sweep. Empty when no fallback has been chosen yet (button
    /// disabled). This pins the selected-only contract independent of the SwiftUI view.
    @Test func testExercisesOnlyTheSelectedSource() {
        #expect(CgmCredentialsView.sourcesToTest(selectedId: "nightscout") == ["nightscout"])
        #expect(CgmCredentialsView.sourcesToTest(selectedId: "dexcom-g7-ble") == ["dexcom-g7-ble"])
        #expect(CgmCredentialsView.sourcesToTest(selectedId: nil).isEmpty)
        #expect(CgmCredentialsView.sourcesToTest(selectedId: "").isEmpty)
    }
}
