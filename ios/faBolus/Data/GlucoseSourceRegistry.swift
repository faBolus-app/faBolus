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
    public static let enabled: [GlucoseSourceDescriptor] = [
        GlucoseSourceDescriptor(id: "dexcom-g7-ble", name: "Dexcom G7 / ONE+ (direct BLE)",
                                sensors: ["Dexcom G7", "Dexcom ONE+"]) { DexcomG7BLESource() },
        GlucoseSourceDescriptor(id: "librelinkup", name: "FreeStyle Libre 2/3 (LibreLinkUp)",
                                sensors: ["FreeStyle Libre 2", "FreeStyle Libre 3"]) { LibreLinkUpSource() },
        GlucoseSourceDescriptor(id: "nightscout", name: "Nightscout (any CGM)",
                                sensors: ["Any"]) { NightscoutSource() },
        GlucoseSourceDescriptor(id: "dexcom-share", name: "Dexcom Share (cloud, last resort)",
                                sensors: ["Dexcom G6", "Dexcom G7"]) { DexcomShareSource() },
        GlucoseSourceDescriptor(id: "healthkit", name: "Eversense (Apple Health)",
                                sensors: ["Eversense E3", "Eversense 365"]) { HealthKitGlucoseSource() },
    ]

    private static let key = "selectedGlucoseSourceId"

    /// The chosen source id, or nil for "none / pump only".
    public static func selectedId() -> String? { UserDefaults.standard.string(forKey: key) }

    /// Persist the chosen source id (nil clears it). Applied on next launch / re-init.
    public static func select(_ id: String?) { UserDefaults.standard.set(id, forKey: key) }

    /// The selected descriptor if it's still available, else nil.
    public static func selected() -> GlucoseSourceDescriptor? {
        guard let id = selectedId() else { return nil }
        return enabled.first { $0.id == id }
    }

    /// Build the selected source, or nil when none is configured/available.
    public static func makeSelected() -> GlucoseSource? { selected()?.make() }
}
