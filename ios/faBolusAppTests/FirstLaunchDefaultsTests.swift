import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P15 E2 — the **exit criterion**: the first-launch safety posture. On a brand-new install (no stored
/// values), nothing that could deliver insulin or silently write to the pump is armed:
///   • remote bolusing is OFF on both surfaces (Garmin + Apple Watch),
///   • the remote-bolus passcode is not required (nothing stored), and
///   • auto pump-clock sync is OFF — so a first connect never silently writes the pump clock without an
///     explicit opt-in (the E2 flip; NOT re-coupled to `advancedControlEnabled`).
///
/// A fresh throwaway `UserDefaults` suite stands in for "first launch", so the assertions read the init
/// FALLBACK defaults without depending on — or clobbering — the real `.standard` domain. Serialized
/// because it toggles the process-wide `BolusPasscodeStore` DEBUG seam and (transiently) the shared
/// `GlucoseFreshness` thresholds, which are saved and restored so no sibling suite is disturbed.
@MainActor
@Suite(.serialized)
struct FirstLaunchDefaultsTests {

    @Test func freshInstallLeavesEverythingDeliverySensitiveOff() {
        // Constructing AppSettings runs `applyFreshness()`, which mutates the shared GlucoseFreshness
        // thresholds. Save + restore them so this exit test never perturbs another suite.
        let savedStale = GlucoseFreshness.staleAfter
        let savedHide = GlucoseFreshness.hideAfter
        defer { GlucoseFreshness.staleAfter = savedStale; GlucoseFreshness.hideAfter = savedHide }

        // A brand-new, empty suite = first launch: every value falls back to its init default.
        let suiteName = "FirstLaunchDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        #expect(settings.garminBolusEnabled == false)
        #expect(settings.watchBolusEnabled == false)
        #expect(settings.autoSyncPumpTime == false)     // E2: no silent pump-clock write without opt-in

        // Remote-bolus passcode: route through the DEBUG in-memory backing (the app-hosted test target
        // can't write the Keychain) and assert nothing is required on a fresh install.
        BolusPasscodeStore.useInMemoryBackingForTests = true
        BolusPasscodeStore.setPasscode(nil)             // fresh slate: no passcode set
        defer { BolusPasscodeStore.setPasscode(nil) }   // leave no residue for other suites
        #expect(BolusPasscodeStore.isRequired == false)
    }
}
