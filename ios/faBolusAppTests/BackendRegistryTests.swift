import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 9 (09-03, P-C): closes RESEARCH Pitfall 1 — deleting the `mockMobi` `BackendDescriptor`
/// (`BackendRegistry.swift:16`) without ALSO patching `ConnectPumpOnboardingView`'s hardcoded
/// demo-backend id would make `BackendRegistry.selected()`'s fallback-to-`enabled[0]` resolve the
/// "Use a demo pump" button to the REAL `TandemBackend` on a device (not a Simulator surprise — a
/// real-BLE surprise). Mirrors `CgmShareOnlyBoundaryTests`' registry-enumeration idiom
/// (construction-time, no live BLE, no hardware dependency).
///
/// Do NOT weaken either `@Test` to "select() didn't throw" (the RESEARCH warning sign) — both
/// assertions below are needed: `enabledContainsNoSimulatedMobi` is RED before the descriptor is
/// deleted (mock-mobi still present), and `onboardingDemoIdResolvesToMockBackendNotTandem` proves
/// the demo id resolves to a `MockBackend` TYPE, not merely a non-throwing call.
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

    /// The onboarding demo id resolves to a `MockBackend` TYPE — never the real `TandemBackend`
    /// (Pitfall 1). Red before the id patch: pre-fix `demoBackendId` was `"mock-mobi"`, so selecting
    /// today's `"mock-tslim"` id would (pre-fix) have hit no descriptor at all and fallen back to
    /// `enabled[0]`, which is `tandem` on a device.
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

    /// Simulated Mobi is fully removed — not merely hidden — from the compiled-in backend set
    /// (MOBI-01, D-01); Simulated t:slim X2 survives as the simulator template.
    @Test func enabledContainsNoSimulatedMobi() {
        let ids = Set(BackendRegistry.enabled.map(\.id))
        #expect(!ids.contains("mock-mobi"), "Simulated Mobi must be removed from BackendRegistry.enabled")
        #expect(ids.contains("mock-tslim"), "Simulated t:slim X2 survives as the simulator template")
    }
}
