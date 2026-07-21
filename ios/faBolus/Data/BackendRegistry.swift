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
        let tandem = BackendDescriptor(id: "tandem", name: "Tandem t:slim X2 / Mobi (real pump)") { TandemBackend() }
        // Two simulators so anyone can try the app with no hardware: the Mobi sim exposes the full
        // advanced-control surface (cartridge/fill, CGM session, profiles…); the t:slim sim is
        // bolus/status only, matching what a real t:slim X2 supports.
        let mockMobi = BackendDescriptor(id: "mock-mobi", name: "Simulated Mobi") { MockBackend(isMobi: true) }
        let mockTslim = BackendDescriptor(id: "mock-tslim", name: "Simulated t:slim X2") { MockBackend(isMobi: false) }
        #if targetEnvironment(simulator)
        return [mockMobi, mockTslim, tandem]
        #else
        return [tandem, mockMobi, mockTslim]
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
