import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that Simulated Mobi is gone from the compiled backend set, and that the onboarding "demo pump"
/// id resolves to MockBackend, never TandemBackend. Falling back to `enabled[0]` on a device would open real BLE.
@MainActor
struct BackendRegistryTests {

    /// The demo-backend id `ConnectPumpOnboardingView`'s "Use a demo pump" button selects. Duplicated
    /// here (not imported — the source is `private` to that file) because THIS literal string is the
    /// safety contract this test pins: it must always resolve to a `MockBackend`, never `TandemBackend`.
    private static let demoBackendId = "mock-tslim"

    /// Restores whatever backend id was persisted before this test ran, so it never leaks state into
    /// other tests or a developer's Simulator (`BackendRegistry.select` writes real `UserDefaults`).
    private func withRestoredSelection(_ body: () -> Void) {
        let key = "selectedBackendId"
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        body()
    }

    /// The onboarding demo id resolves to a `MockBackend` type — never the real `TandemBackend`.
    /// A missing id would fall back to `enabled[0]`, which is `tandem` on a device.
    @Test func onboardingDemoIdResolvesToMockBackendNotTandem() {
        withRestoredSelection {
            BackendRegistry.select(Self.demoBackendId)
            let resolved = BackendRegistry.selected()
            #expect(resolved.id == Self.demoBackendId,
                    "the demo id must resolve to itself, not silently fall back to a different backend")
            let instance = resolved.make()
            #expect(instance is MockBackend,
                    "the onboarding demo button must resolve to a MockBackend, never TandemBackend")
            #expect(!(instance is TandemBackend),
                    "the onboarding demo button must never resolve to the REAL TandemBackend (Pitfall 1)")
        }
    }

    /// Simulated Mobi is fully removed — not merely hidden — from the compiled-in backend set.
    /// Simulated t:slim X2 survives as the simulator template.
    @Test func enabledContainsNoSimulatedMobi() {
        let ids = Set(BackendRegistry.enabled.map(\.id))
        #expect(!ids.contains("mock-mobi"), "Simulated Mobi must be removed from BackendRegistry.enabled")
        #expect(ids.contains("mock-tslim"), "Simulated t:slim X2 survives as the simulator template")
    }
}
