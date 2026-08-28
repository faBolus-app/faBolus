import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that a fresh install leaves remote bolusing, auto pump-clock sync, and the glucose badge off. A first connect must not silently write the pump clock or arm a dose path.
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
        #expect(settings.autoSyncPumpTime == false)     // E2: no silent pump-clock write without opt-in
        // App-icon glucose badge is opt-in — OFF on a fresh install.
        #expect(settings.glucoseBadgeEnabled == false)

        // Remote-bolus passcode: route through the DEBUG in-memory backing (the app-hosted test target
        // can't write the Keychain) and assert nothing is required on a fresh install.
        BolusPasscodeStore.useInMemoryBackingForTests = true
        BolusPasscodeStore.setPasscode(nil)             // fresh slate: no passcode set
        defer { BolusPasscodeStore.setPasscode(nil) }   // leave no residue for other suites
        #expect(BolusPasscodeStore.isRequired == false)
    }
}
