import Foundation

/// Describes one pump backend available to the app. The app keeps a compile-time manifest of these
/// (its `BackendRegistry`) and builds the selected one. Adding a backend is: implement `PumpBackend`
/// and append a `BackendDescriptor`.
public struct BackendDescriptor: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Builds a fresh backend instance. `@MainActor` because backends are main-actor bound.
    public let make: @MainActor () -> PumpBackend
    public init(id: String, name: String, make: @escaping @MainActor () -> PumpBackend) {
        self.id = id; self.name = name; self.make = make
    }
}
