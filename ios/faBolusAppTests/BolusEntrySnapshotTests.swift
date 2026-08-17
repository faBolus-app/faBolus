import Testing
import Foundation
import SnapshotTesting
@testable import faBolus

/// **D-06b (Phase 09.17-04).** Compact-width iPhone visual-regression net for `BolusEntryView`,
/// recorded against the CURRENT (pre-readable-width-cap) code — before this plan's Task 2 adds the
/// regular-width `.frame(maxWidth: AppTheme.iPadReadableContentMaxWidth)` cap. The compact/`else`
/// branch (no frame applied) is byte-identical before and after that change (D-06a structural
/// isolation); this test is the regression net proving it stays that way.
///
/// Mirrors `DashboardSnapshotTests`/`SettingsSnapshotTests`'s idiom exactly: `.image(layout:
/// .sizeThatFits)` is device-agnostic (Pitfall 5) — tracks whatever Simulator `scripts/test-ios.sh`
/// auto-detects, never a hardcoded `.device(config:)` preset.
///
/// `BolusEntryView(model:, embedded:)` in `embedded: true` mode (matches its tab-bar usage) with the
/// default/empty entry state (no `carbsText`/`unitsText` typed) — the view's own `@State` defaults.
@MainActor
@Suite struct BolusEntrySnapshotTests {
    @Test func bolusEntryCompactWidthEmbeddedDefaultEmpty() async {
        let backend = MockBackend()
        // Deviation (Rule 3, mirrors DashboardSnapshotTests): a deterministic fixture so the
        // rendered content (status row / connection state feeding the calculator inputs) doesn't
        // vary run-to-run.
        backend.seedDeterministicGlucoseForTesting()
        // FB-03 (mirrors AppModelBehaviorTests.makeModel): a dedicated ledger file so this test's
        // AppModel never shares a durable-ledger path with another (possibly parallel) test.
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bolus-entry-snapshot-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        await model.connect()

        let view = BolusEntryView(model: model, embedded: true)
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
    }
}
