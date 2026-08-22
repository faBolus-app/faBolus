import Testing
import Foundation
@testable import faBolus

/// Phase 9 (09-04, MOBI-04, D-06): `criticalAlertsEnabled`'s default is flipped from Mobi-derived
/// (`PumpModelStore.isMobi() == true`) to an explicit t:slim OFF, decoupled from the Mobi check, and a
/// pre-Phase-9 persisted `true` is force-reset to `false` EXACTLY ONCE on upgrade via a new dedicated
/// idempotent-once guard key (`criticalAlertsForceResetV050`) — owner-chosen uniform state over leaving
/// persisted values. The capability path (`NotificationCoordinator` read, `NotificationSettingsView`
/// toggle) is untouched and proven reachable elsewhere; this suite covers only the default + migration.
///
/// Mirrors `FirstLaunchDefaultsTests`'s idiom: a fresh, throwaway `UserDefaults` suite stands in for a
/// device install so these assertions read `AppSettings.init`'s fallback/migration logic without
/// depending on — or clobbering — the real `.standard` domain or `AppSettings.shared`.
///
/// `PumpModelStore` itself is hardcoded to `UserDefaults.standard` (not injectable), so
/// `defaultIsOffForTslimDecoupledFromMobi` drives it against `.standard` to prove decoupling — save +
/// restore its real persisted value so no sibling suite (or a real device's detected-pump state, if this
/// ever ran outside CI) is disturbed. `.serialized` because of that shared mutable global.
@MainActor
@Suite(.serialized)
struct AppSettingsMigrationTests {

    private static let forceResetKey = "criticalAlertsForceResetV050"
    private static let enabledKey = "criticalAlertsEnabled"

    private func freshSuite() -> UserDefaults {
        let name = "AppSettingsMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// With no persisted value, `criticalAlertsEnabled` defaults to `false` regardless of
    /// `PumpModelStore.isMobi()` — proving the default is decoupled from the Mobi check, not merely
    /// that it happens to read false today.
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
            #expect(settings.criticalAlertsEnabled == false,
                    "criticalAlertsEnabled must default to false for isMobi == \(isMobi) — decoupled from PumpModelStore")
        }
    }

    /// A persisted pre-Phase-9 `criticalAlertsEnabled == true` (from the old Mobi-derived default), with
    /// the guard key unset (never migrated), is force-reset to `false` exactly once on upgrade, and the
    /// guard key is set so the reset does not re-fire.
    @Test func persistedTrueIsForceResetOnceOnUpgrade() {
        let defaults = freshSuite()
        defaults.set(true, forKey: Self.enabledKey)
        // Guard key deliberately absent — simulates a pre-Phase-9 install that has never run this migration.
        #expect(defaults.object(forKey: Self.forceResetKey) == nil)

        let settings = AppSettings(defaults: defaults)

        #expect(settings.criticalAlertsEnabled == false,
                "a persisted true from a pre-Phase-9 install must be force-reset to false on the first post-upgrade launch")
        #expect(defaults.bool(forKey: Self.forceResetKey) == true,
                "the guard key must be set after the one-time force-reset fires")
        #expect(defaults.object(forKey: Self.enabledKey) as? Bool == false,
                "the persisted UserDefaults value itself must be overwritten to false, not just the in-memory property")
    }

    /// With the guard key already set (the one-time migration has already fired on a prior launch), a
    /// user who re-enabled critical alerts AFTER the upgrade must NOT have that later choice clobbered on
    /// a subsequent launch — the force-reset must not re-fire.
    @Test func laterUserOptInIsNotReReset() {
        let defaults = freshSuite()
        defaults.set(true, forKey: Self.forceResetKey)   // migration already ran once, previously
        defaults.set(true, forKey: Self.enabledKey)       // user opted back in after that migration

        let settings = AppSettings(defaults: defaults)

        #expect(settings.criticalAlertsEnabled == true,
                "a later user opt-in must survive — the one-time migration must not re-fire once its guard key is set")
        #expect(defaults.object(forKey: Self.enabledKey) as? Bool == true,
                "the persisted value itself must remain true — not overwritten by a re-fired migration")
    }

    /// Sanity: repeated `AppSettings` construction over the SAME suite after the migration has fired once
    /// stays idempotent — a second and third `init` neither re-reset nor otherwise perturb the value.
    @Test func migrationIsIdempotentAcrossRepeatedInit() {
        let defaults = freshSuite()
        defaults.set(true, forKey: Self.enabledKey)   // pre-Phase-9 persisted true, guard unset

        _ = AppSettings(defaults: defaults)   // first post-upgrade launch: force-resets to false
        #expect(defaults.object(forKey: Self.enabledKey) as? Bool == false)

        defaults.set(true, forKey: Self.enabledKey)   // user opts back in
        _ = AppSettings(defaults: defaults)   // second launch: guard already set, must not re-reset
        #expect(defaults.object(forKey: Self.enabledKey) as? Bool == true)

        let third = AppSettings(defaults: defaults)   // third launch: still must not re-reset
        #expect(third.criticalAlertsEnabled == true)
    }
}
