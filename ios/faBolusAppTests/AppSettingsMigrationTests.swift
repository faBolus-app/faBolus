import Testing
import Foundation
@testable import faBolus

/// `criticalAlertsEnabled` defaults OFF for every pump family.
@MainActor
@Suite(.serialized)
struct AppSettingsMigrationTests {

    private func freshSuite() -> UserDefaults {
        let name = "AppSettingsMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// With no persisted value, `criticalAlertsEnabled` defaults to `false` regardless of
    /// `PumpModelStore.isMobi()` — proving the default is decoupled from the Mobi check.
    @Test func defaultIsOffForTslimDecoupledFromMobi() {
        // Save + restore the real `.standard`-backed detected-pump flag: PumpModelStore hardcodes
        // UserDefaults.standard and has no injectable seam.
        let savedIsMobi = PumpModelStore.isMobi()
        defer {
            if let saved = savedIsMobi { PumpModelStore.set(isMobi: saved) } else { PumpModelStore.clear() }
        }

        for isMobi in [true, false] {
            PumpModelStore.set(isMobi: isMobi)
            let defaults = freshSuite()
            let settings = AppSettings(defaults: defaults)
            #expect(
                settings.criticalAlertsEnabled == false,
                "criticalAlertsEnabled must default to false for isMobi == \(isMobi) — decoupled from PumpModelStore")
        }
    }
}

/// The retired eating/Nudge surface left five orphaned `UserDefaults` keys behind (no code reads,
/// displays, or deletes them any more — the two erase paths deliberately don't touch PREFERENCES).
/// A one-time launch purge removes them exactly once.
@MainActor
@Suite(.serialized)
struct EatingResiduePurgeTests {

    private static let purgeGuardKey = "eatingResiduePurgeV1"

    private func freshSuite() -> UserDefaults {
        let name = "EatingResiduePurgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A tester upgrading from a build that still had the eating/Nudge surface has all five orphaned
    /// keys removed on the very next launch, and the guard key is set so the purge does not re-fire.
    @Test func allFiveOrphanedKeysArePurgedOnceOnUpgrade() {
        let defaults = freshSuite()
        for key in AppSettings.retiredEatingResidueKeys { defaults.set(true, forKey: key) }
        #expect(defaults.object(forKey: Self.purgeGuardKey) == nil)

        _ = AppSettings(defaults: defaults)

        for key in AppSettings.retiredEatingResidueKeys {
            #expect(
                defaults.object(forKey: key) == nil,
                "orphaned key '\(key)' must be removed by the one-time purge")
        }
        #expect(
            defaults.bool(forKey: Self.purgeGuardKey) == true,
            "the purge guard key must be set after the one-time purge fires")
    }

    /// Idempotent: once the guard key is set, a later launch must not re-run the purge (there is
    /// nothing left to purge, but the guard itself must not be re-evaluated destructively either).
    @Test func purgeDoesNotReRunOnceGuardKeyIsSet() {
        let defaults = freshSuite()
        defaults.set(true, forKey: Self.purgeGuardKey)  // purge already ran once, previously
        // Simulate a key re-appearing after the purge (e.g. a restored backup) — the guard must still
        // prevent a second sweep from firing, since the purge is a one-time upgrade action, not a
        // standing invariant.
        defaults.set(true, forKey: "eatingNudgesEnabled")

        _ = AppSettings(defaults: defaults)

        #expect(
            defaults.object(forKey: "eatingNudgesEnabled") as? Bool == true,
            "the purge must not re-fire once its guard key is set")
    }

    /// Sanity: repeated `AppSettings` construction over the SAME suite after the purge has fired once
    /// stays idempotent across a second and third `init`.
    @Test func purgeIsIdempotentAcrossRepeatedInit() {
        let defaults = freshSuite()
        for key in AppSettings.retiredEatingResidueKeys { defaults.set(true, forKey: key) }

        _ = AppSettings(defaults: defaults)  // first post-upgrade launch: purges all five keys
        for key in AppSettings.retiredEatingResidueKeys {
            #expect(defaults.object(forKey: key) == nil)
        }

        _ = AppSettings(defaults: defaults)  // second launch: guard already set, nothing to re-purge
        let third = AppSettings(defaults: defaults)  // third launch: still nothing to re-purge
        _ = third
        #expect(defaults.bool(forKey: Self.purgeGuardKey) == true)
    }
}
