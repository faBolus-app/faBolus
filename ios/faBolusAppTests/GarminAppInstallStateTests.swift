import Testing
import Foundation
@testable import faBolus

/// **I-M2.** Pins `garminClassifyAppInstallState` — the ConnectIQ-free classifier for a `getAppStatus`
/// result. It lives OUTSIDE `#if GARMIN` (next to `garminSendDisposition`/`GarminMessageReadiness`)
/// precisely so it compiles and is unit-testable in the default (non-GARMIN) test target, where the
/// ConnectIQ-typed `IQAppStatus` is not.
///
/// LOAD-BEARING CONTEXT: `registerApp()` used to arm readiness ONLY when `getAppStatus` returned
/// `installed==true`, with no distinct signal for "not installed" vs "the completion itself never
/// resolved a status" — both silently left `garminStatus` showing the synchronous "✓" set earlier in
/// `restoreDevice()`/`handleOpenURL()`, so a beta-vs-official app-id mismatch (or a genuinely
/// uninstalled watch app) was a silent dead state (readiness never arms, no visible explanation). This
/// classifier makes all three states (installed / notInstalled / unknown) explicit and testable.
struct GarminAppInstallStateTests {

    @Test func installedTrueClassifiesAsInstalled() {
        #expect(garminClassifyAppInstallState(installed: true) == .installed)
    }

    /// The key not-silent-dead-end case: an explicit `false` (app-id mismatch or genuinely not
    /// installed) must classify as `.notInstalled`, never `.unknown` or `.installed`.
    @Test func installedFalseClassifiesAsNotInstalled() {
        #expect(garminClassifyAppInstallState(installed: false) == .notInstalled)
    }

    /// `nil` (the completion itself never resolved a status — e.g. `appStatus` was nil) is its OWN
    /// fail-safe state, distinct from both `installed` and `notInstalled` — it must NEVER be silently
    /// treated as `installed` (which would incorrectly arm readiness) nor as `notInstalled` (which
    /// would incorrectly offer a store link for an app that may well be installed).
    @Test func nilInstalledClassifiesAsUnknown() {
        #expect(garminClassifyAppInstallState(installed: nil) == .unknown)
    }

    // MARK: status text + store-link offer (GarminDiagnostics.AppInstallState)

    @Test func installedOffersNoStoreLink() {
        #expect(GarminDiagnostics.AppInstallState.installed.offerStoreLink == false)
    }

    /// The visible, actionable state I-M2 requires: an explicit store-link offer.
    @Test func notInstalledOffersStoreLinkWithExplicitStatusText() {
        let state = GarminDiagnostics.AppInstallState.notInstalled
        #expect(state.offerStoreLink == true)
        #expect(
            state.statusText.lowercased().contains("not installed")
                || state.statusText.lowercased().contains("app-id mismatch"))
    }

    @Test func unknownOffersNoStoreLink() {
        #expect(GarminDiagnostics.AppInstallState.unknown.offerStoreLink == false)
    }
}
