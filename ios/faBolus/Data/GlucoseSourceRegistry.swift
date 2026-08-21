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
    /// (last resort), and HealthKit (Eversense).
    public static let enabled: [GlucoseSourceDescriptor] = {
        var list: [GlucoseSourceDescriptor] = [
            // dexcom-g7-ble (DexcomG7BLESource), dexcom-g6-ble (DexcomG6BLESource), and librelinkup
            // (LibreLinkUpSource) removed from narrow `main` — Phase 1, Plan 03 (G7, CGM-01/CGM-02)
            // and Plan 02 (G6 + LibreLinkUp, CGM-03/CGM-04). Compile-excluded via
            // FABOLUS_CGM_G7=0 / FABOLUS_CGM_G6=0 / FABOLUS_CGM_LIBRELINKUP=0 in
            // scripts/generate-project.sh; the source files themselves stay checked in (still built
            // on dev/cgm-extra at =1).
            GlucoseSourceDescriptor(id: "nightscout", name: "Nightscout (any CGM)",
                                    sensors: ["Any"]) { _ in NightscoutSource() },
            GlucoseSourceDescriptor(id: "dexcom-share", name: "Dexcom Share (cloud, last resort)",
                                    sensors: ["Dexcom G6", "Dexcom G7"]) { _ in DexcomShareSource() },
        ]
        // D-13 (Phase 09.23): the existing HealthKit CGM source is part of the WHOLE HealthKit
        // surface the single FABOLUS_HEALTHKIT toggle gates — a free/unprovisioned build must not
        // register it at all, not just skip selecting it, so the entitlement-stripped build never
        // even references HealthKitGlucoseSource. Gate the call site here, not the Shared/ class
        // definition (which compiles unconditionally as long as nothing references it).
        #if FABOLUS_HEALTHKIT
        list.append(GlucoseSourceDescriptor(id: "healthkit", name: "Apple Health (xDrip / Eversense)",
                                sensors: ["xDrip4iOS (any sensor)", "Eversense E3", "Eversense 365"]) { _ in HealthKitGlucoseSource() })
        #endif
        // xdrip-appgroup (XDripAppGroupSource) removed from narrow `main` — Phase 1, Plan 01 (CGM-05).
        // Compile-excluded via FABOLUS_CGM_XDRIP=0 in scripts/generate-project.sh; the source file
        // itself stays checked in (still built on experimental/cgm-extra at FABOLUS_CGM_XDRIP=1).
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
    /// `glucoseSourceProbe`, never a second ephemeral central). On narrow `main` it is still exercised
    /// by `CgmConnectionKindTests` (which builds each source by id to read its `connectionKind`). The
    /// restore-identifier invariant it also guards — that the by-id path passes `restoreStateEnabled:
    /// false`, the sole guard against the dup-restore-id SIGABRT — has NO direct-BLE CGM consumer on
    /// narrow `main` (no `.localBLE` source ships here), so it is regression-tested only on the branches
    /// where such a source still compiles (`dev/cgm-extra`: `Dexcom{G6,G7}RestoreIdentifierTests`).
    /// Keeping it (and `CgmCredentialsView.sourcesToTest`) is the chosen low-risk option; if narrow
    /// `main` ever regains a direct-BLE CGM source, restore that restore-identifier coverage in the
    /// same change.
    public static func make(id: String) -> GlucoseSource? { descriptor(id: id)?.make(false) }
}
