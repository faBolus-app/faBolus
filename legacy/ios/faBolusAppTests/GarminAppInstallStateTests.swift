import Testing
import Foundation
@testable import faBolus

/// Pins that `getAppStatus` distinguishes installed, not-installed, and unknown. Treating unknown as installed would arm readiness with no watch app; treating it as not-installed would offer a store link for an app that may already be there.
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

    /// The visible, actionable state: an explicit store-link offer.
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
