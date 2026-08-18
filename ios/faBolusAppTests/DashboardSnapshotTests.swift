import Testing
import Foundation
import SnapshotTesting
@testable import faBolus

/// **D-06b (Phase 09.17-01).** Compact-width iPhone visual-regression net for the iPad-adaptive
/// retrofit — the first surface this phase's snapshot infrastructure protects. A committed
/// reference image of a POPULATED `DashboardView` (real glucose/IOB/pump-detail content, not an
/// empty state) at compact width; any future compact-width drift on this screen fails this test.
///
/// `.image(layout: .sizeThatFits)` is device-agnostic (Pitfall 5) — it tracks whatever Simulator
/// `scripts/test-ios.sh` auto-detects, never a hardcoded `.device(config:)` preset, so this test
/// does not require re-recording on a fresh Xcode/Simulator install the way a pinned device preset
/// would.
///
/// `MockBackend` seeds a fully-populated `PumpSnapshot` + 3h glucose/IOB history at `init` (mirrors
/// `AppModelBehaviorTests.makeModel`'s fixture shape); `AppModel(source:)` copies that history in
/// synchronously (`AppModel.swift:803`), so the chart/pills/pump-details render real content with
/// no `await` needed. `model.connect()` (mirrors `makeModel(connected: true)`) additionally flips
/// `snapshot.connection` to `.connected` for a representative status ring — captured immediately
/// after `connect()` returns, well before `MockBackend`'s 5-second `tick()` timer could fire and
/// mutate the seeded values out from under the snapshot.
///
/// Deviation (Rule 1 — found during this task): `GlucoseChartView.chartXScale`'s domain end is a
/// live `Date()`, so the exact sub-pixel position of every chart line/point/dashed gridline shifts
/// by however many seconds elapse between the recording run and any later verify run — confirmed by
/// diffing two consecutive runs (~2,300 of 3.16M pixels, confined to the chart region, well under a
/// 1% budget). `precision`/`perceptualPrecision` (the library's own documented tool "useful for
/// animations/timing") absorb that sub-pixel jitter while still catching a REAL structural
/// regression (a moved/missing element, wrong color, or layout break differs by orders of magnitude
/// more than this).
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
