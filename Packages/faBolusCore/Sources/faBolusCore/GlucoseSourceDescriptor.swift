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
    public let make: @MainActor () -> GlucoseSource
    public init(id: String, name: String, sensors: [String] = [],
                make: @escaping @MainActor () -> GlucoseSource) {
        self.id = id; self.name = name; self.sensors = sensors; self.make = make
    }
}
