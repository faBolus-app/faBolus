import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P12 (group D) — the phone host feeds `BolusGate` from its own `PumpSnapshot` + `AccessPolicy`. Pins
/// that `AppModel.bolusGate` maps the live snapshot correctly (the pure gate logic is covered by
/// `BolusGateTests`; this covers the host wiring the phone `BolusEntryView` now depends on).
@Suite(.serialized) @MainActor
struct BolusGateHostFeedTests {
    private func makeModel() -> (AppModel, MockBackend) {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bg-\(UUID().uuidString).json")
        return (AppModel(source: backend, ledgerStoreURL: url), backend)
    }
    /// Clean gate state so a sibling test can't leave child/read-only set; advanced-control on (the Mobi
    /// MockBackend needs it for the funnel's capability gate, matching the shipped UI).
    private func withClean(_ body: () async -> Void) async {
        let s = AppSettings.shared
        let child = s.childModeEnabled, ro = s.phoneReadOnly, adv = s.advancedControlEnabled
        s.childModeEnabled = false; s.phoneReadOnly = false; s.advancedControlEnabled = true
        await body()
        s.childModeEnabled = child; s.phoneReadOnly = ro; s.advancedControlEnabled = adv
    }

    @Test func connectedInBoundsAllows() async {
        await withClean {
            let (model, backend) = makeModel()
            await backend.connect()
            let g = model.bolusGate(amount: 2.0, minimum: 0.05)
            #expect(g.canBolus)
            #expect(g.reason == nil)
        }
    }

    @Test func neverConnectedReportsPumpNotLinked() async {
        await withClean {
            let (model, _) = makeModel()   // stays .disconnected — no pump link
            let g = model.bolusGate(amount: 2.0, minimum: 0.05)
            #expect(!g.canBolus)
            #expect(g.reason == .pumpNotLinked)
        }
    }

    @Test func overMaxReportsAboveMax() async {
        await withClean {
            let (model, backend) = makeModel()
            await backend.connect()
            let g = model.bolusGate(amount: 999, minimum: 0.05)   // MockBackend max is 25 U
            #expect(!g.canBolus)
            #expect(g.reason == .aboveMax(backend.snapshot.maxBolusUnits))
        }
    }
}
