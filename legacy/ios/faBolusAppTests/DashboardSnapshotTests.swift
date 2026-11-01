import Testing
import Foundation
import SnapshotTesting
@testable import faBolus

/// Compact dashboard visual pin so glucose/IOB/pump-detail layout cannot silently drift;
/// perceptual tolerance absorbs live-`Date()` chart jitter only.
@MainActor
@Suite struct DashboardSnapshotTests {
    @Test func dashboardCompactWidthDefaultPopulated() async {
        let backend = MockBackend()
        // Deviation (Rule 3): `seedHistory()`'s glucose trace is randomized (`Double.random`) for a
        // lively Simulator/preview experience, which makes the raw `MockBackend()` fixture unusable
        // as a golden-image reference — see `seedDeterministicGlucoseForTesting()`'s doc comment.
        backend.seedDeterministicGlucoseForTesting()
        // FB-03 (mirrors AppModelBehaviorTests.makeModel): a dedicated ledger file so this test's
        // AppModel never shares a durable-ledger path with another (possibly parallel) test.
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dashboard-snapshot-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        await model.connect()

        let view = DashboardView(model: model)
        assertSnapshot(of: view, as: .image(precision: 0.99, perceptualPrecision: 0.98, layout: .sizeThatFits))
    }
}
