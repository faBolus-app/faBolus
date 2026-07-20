import Foundation

/// A pump backend available in this build. Contributors add a backend by (1) adding its module and
/// (2) appending a `BackendDescriptor` to `BackendRegistry.enabled` — a **compile-time manifest**
/// (iOS has no dynamic plugins, so every backend is compiled in and selected at runtime).
public struct BackendDescriptor: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Builds a fresh backend instance. `@MainActor` because backends are main-actor bound.
    public let make: @MainActor () -> PumpBackend
    public init(id: String, name: String, make: @escaping @MainActor () -> PumpBackend) {
        self.id = id; self.name = name; self.make = make
    }
}

@MainActor
public enum BackendRegistry {
    /// The backends compiled into this build. **Add a backend here.** First entry is the default.
    /// On device the real pump backend leads; in the Simulator the mock leads.
    public static let enabled: [BackendDescriptor] = {
        let tandem = BackendDescriptor(id: "tandem", name: "Tandem t:slim X2 / Mobi") { LivePumpDataSource() }
        let mock = BackendDescriptor(id: "mock", name: "Simulator (mock)") { MockPumpDataSource() }
        #if targetEnvironment(simulator)
        return [mock, tandem]
        #else
        return [tandem, mock]
        #endif
    }()

    private static let key = "selectedBackendId"

    /// The user-selected backend (persisted) if it's still available, else the default (first).
    public static func selected() -> BackendDescriptor {
        let id = UserDefaults.standard.string(forKey: key)
        return enabled.first { $0.id == id } ?? enabled[0]
    }

    /// Persist the chosen backend id (applied on next launch, since the app builds one backend).
    public static func select(_ id: String) { UserDefaults.standard.set(id, forKey: key) }

    /// Build the selected backend instance.
    public static func makeSelected() -> PumpBackend { selected().make() }
}
