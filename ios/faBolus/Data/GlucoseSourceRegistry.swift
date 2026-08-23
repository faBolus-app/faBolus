import Foundation
import faBolusCore

/// The compile-time manifest of glucose **failover** sources in this build (iOS has no dynamic
/// plugins, so every source is compiled in and selected at runtime). Mirrors `BackendRegistry`.
/// Add a source by implementing `GlucoseSource` and appending a `GlucoseSourceDescriptor` to
/// `enabled`.
@MainActor
public enum GlucoseSourceRegistry {
    /// Sources compiled into this build. Empty selection = pump-relayed glucose only (no failover).
    /// Added per phase: Dexcom G7 passive BLE, then LibreLinkUp, Nightscout, Dexcom Share
    /// (cloud fallback). HealthKit (Eversense) was removed from narrow `main` in Phase 5 (HEALTH-01) —
    /// see dev/healthkit's REINTEGRATION.md for the pre-removal descriptor shape. Nightscout was
    /// removed from narrow `main` in Phase 5 (HEALTH-02) — see dev/nightscout's REINTEGRATION.md.
    public static let enabled: [GlucoseSourceDescriptor] = {
        var list: [GlucoseSourceDescriptor] = [
            // dexcom-g7-ble, dexcom-g6-ble, and librelinkup removed from narrow `main` — Phase 1,
            // Plan 03 (G7, CGM-01/CGM-02) and Plan 02 (G6 + LibreLinkUp, CGM-03/CGM-04), then
            // retro-cleaned to a physical `git rm` in Phase 2.5 (D-01/D-07, CLEAN-03) — the source
            // files no longer exist on `main` at all; they are preserved on origin/dev/cgm-extra.
            GlucoseSourceDescriptor(id: "dexcom-share", name: "Dexcom Share (cloud)",
                                    sensors: ["Dexcom G6", "Dexcom G7"]) { _ in DexcomShareSource() },
        ]
        // xdrip-appgroup removed from narrow `main` — Phase 1, Plan 01 (CGM-05), then git rm'd
        // outright in Phase 2.5 (D-07, CLEAN-03); preserved on origin/dev/cgm-extra.
        return list
    }()

    /// Every descriptor — used for id lookups.
    private static var all: [GlucoseSourceDescriptor] { enabled }

    private static let key = "selectedGlucoseSourceId"

    /// The chosen source id, or nil for "none / pump only".
    public static func selectedId() -> String? { UserDefaults.standard.string(forKey: key) }

    /// Persist the chosen source id (nil clears it). Applied on next launch / re-init. Also clears
    /// the crash guard so a re-selected source is auto-started again on the next launch.
    public static func select(_ id: String?) {
        UserDefaults.standard.set(id, forKey: key)
        UserDefaults.standard.removeObject(forKey: "glucoseSourceCrashGuard")
    }

    /// The selected descriptor if it's still available, else nil.
    public static func selected() -> GlucoseSourceDescriptor? {
        guard let id = selectedId() else { return nil }
        return all.first { $0.id == id }
    }

    /// Build the selected source, or nil when none is configured/available. The ONE production
    /// instance (D-06) — passes `restoreStateEnabled: true`.
    public static func makeSelected() -> GlucoseSource? { selected()?.make(true) }

    /// The descriptor for a specific source id (for the credentials "test all" diagnostic).
    public static func descriptor(id: String) -> GlucoseSourceDescriptor? { all.first { $0.id == id } }
    /// Build a specific source by id (for testing a not-necessarily-selected source). This is the
    /// ephemeral `CgmCredentialsView` "Test" path — always `restoreStateEnabled: false` (D-06), so it
    /// can never collide with the production instance's restore identifier.
    ///
    /// W-04 (D-14) — KEEP-WITH-COMMENT: this has ZERO remaining PRODUCTION call sites (the live Test
    /// flow now observes the already-running `AppModel.glucoseSource` production instance via
    /// `glucoseSourceProbe`, never a second ephemeral central). It is still exercised by
    /// `DexcomG6RestoreIdentifierTests`, which pins the invariant that the by-id build path carries
    /// `restoreStateEnabled: false` — the sole guard against the dup-restore-id SIGABRT. Keeping it
    /// (and `CgmCredentialsView.sourcesToTest`) is the chosen low-risk option under full-hardening
    /// scope; do NOT delete either without migrating those test call sites in the same change.
    public static func make(id: String) -> GlucoseSource? { descriptor(id: id)?.make(false) }
}
