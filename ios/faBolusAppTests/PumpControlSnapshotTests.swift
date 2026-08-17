import Testing
import Foundation
import SnapshotTesting
@testable import faBolus

/// **D-06b (Phase 09.17-04).** Compact-width iPhone visual-regression net for `PumpControlView`,
/// recorded against the CURRENT (pre-readable-width-cap) code — before this plan's Task 2 adds the
/// regular-width `.frame(maxWidth: AppTheme.iPadReadableContentMaxWidth)` cap. The compact/`else`
/// branch (no frame applied) is byte-identical before and after that change (D-06a structural
/// isolation); this test is the regression net proving it stays that way.
///
/// Mirrors `DashboardSnapshotTests`/`SettingsSnapshotTests`/`BolusEntrySnapshotTests`'s idiom
/// exactly: `.image(layout: .sizeThatFits)` is device-agnostic (Pitfall 5) — tracks whatever
/// Simulator `scripts/test-ios.sh` auto-detects, never a hardcoded `.device(config:)` preset.
///
/// `PumpControlView(model:)` in its default connected state (`model.connect()`, matching
/// `AppModelBehaviorTests.makeModel(connected: true)`'s fixture shape) — `model.pumpReady` becomes
/// true, so the view renders its normal (not "Pump not connected") controls.
@MainActor
@Suite struct PumpControlSnapshotTests {
    @Test func pumpControlCompactWidthDefaultConnected() async {
        let backend = MockBackend()
        // Deviation (Rule 3, mirrors DashboardSnapshotTests): a deterministic fixture so the
        // rendered content doesn't vary run-to-run.
        backend.seedDeterministicGlucoseForTesting()
        // FB-03 (mirrors AppModelBehaviorTests.makeModel): a dedicated ledger file so this test's
        // AppModel never shares a durable-ledger path with another (possibly parallel) test.
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pump-control-snapshot-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        await model.connect()

        let view = PumpControlView(model: model)
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
    }
}
