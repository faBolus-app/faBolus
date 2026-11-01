import Foundation
import faBolusCore

/// The compile-time manifest of pump backends in this build (iOS has no dynamic plugins, so every
/// backend is compiled in and selected at runtime). Add a backend by implementing `PumpBackend` and
/// appending a `BackendDescriptor` to `enabled`.
@MainActor
public enum BackendRegistry {
    /// The backends compiled into this build. **Add a backend here.** First entry is the default.
    /// On device the real pump backend leads; in the Simulator the mock leads.
    public static let enabled: [BackendDescriptor] = {
        let tandem = BackendDescriptor(id: "tandem", name: "Tandem t:slim X2 (real pump)") { TandemBackend() }
        // Simulated Mobi is not compiled in — narrow main is t:slim X2 only, so the one surviving
        // simulator matches what a real t:slim X2 supports (bolus/status only).
        let mockTslim = BackendDescriptor(id: "mock-tslim", name: "Simulated t:slim X2") { MockBackend(isMobi: false) }
        #if targetEnvironment(simulator)
        return [mockTslim, tandem]
        #else
        return [tandem, mockTslim]
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
