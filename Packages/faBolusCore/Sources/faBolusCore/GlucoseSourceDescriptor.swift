import Foundation

/// Describes one glucose (CGM) failover source available to the app. The app keeps a compile-time
/// manifest of these (`GlucoseSourceRegistry`) and builds the selected one. Adding a source is:
/// implement `GlucoseSource` and append a `GlucoseSourceDescriptor` — mirrors `BackendDescriptor`.
public struct GlucoseSourceDescriptor: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Sensors this source can serve, for display/selection (e.g. ["Dexcom G7", "Dexcom ONE+"]).
    public let sensors: [String]
    /// Builds a fresh source instance. `@MainActor` because sources are main-actor bound.
    ///
    /// `restoreStateEnabled`: true for the one long-lived production instance
    /// (`GlucoseSourceRegistry.makeSelected()`), false for the ephemeral credentials "Test" instance
    /// (`GlucoseSourceRegistry.make(id:)`). A source that owns a `CBCentralManager` with a restore
    /// identifier uses this to scope that identifier to at most one live manager per process — two
    /// managers sharing a restore-identifier string is a CoreBluetooth SIGABRT. Most descriptor
    /// closures ignore the flag (`{ _ in SomeSource() }`).
    public let make: @MainActor (_ restoreStateEnabled: Bool) -> GlucoseSource
    public init(id: String, name: String, sensors: [String] = [],
                make: @escaping @MainActor (_ restoreStateEnabled: Bool) -> GlucoseSource) {
        self.id = id; self.name = name; self.sensors = sensors; self.make = make
    }
}
