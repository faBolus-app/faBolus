import Testing
import Foundation
import SnapshotTesting
@testable import faBolus

/// **D-06b (Phase 09.17-02).** Compact-width iPhone visual-regression net for `SettingsView`'s
/// compact/`else` branch (`NavigationStack { SettingsLockGate { settingsList } }`). The reference image
/// was re-recorded 2026-08-23 after an intentional layout change: "Privacy & data" moved out of its own
/// section (below the Safety read-only toggle) up into the category list, between "Remotes & devices" and
/// "About & help" (owner request). The earlier D-06a "byte-identical settingsList" invariant no longer
/// holds — this test is now the regression net for the CURRENT layout.
///
/// Mirrors `DashboardSnapshotTests`'s idiom exactly (Phase 09.17-01): `.image(layout: .sizeThatFits)`
/// is device-agnostic (Pitfall 5) — tracks whatever Simulator `scripts/test-ios.sh` auto-detects,
/// never a hardcoded `.device(config:)` preset.
///
/// **WR-03 gap closure (Phase 09.17-06):** `seedDeterministicGlucoseForTesting()` fixes
/// `snapshot.glucoseDate` to exactly `Date() - 600s` at the moment it's called during setup, but any
/// on-screen "N min ago"-style CGM-age readout is computed from `Date().timeIntervalSince(glucoseDate)`
/// at RENDER time — i.e. `600s + however long elapses between seeding and rendering`. On a slow/loaded
/// CI runner that gap can cross a minute boundary (e.g. "10 min ago" -> "11 min ago"), which would fail
/// this test against its committed reference image for reasons having nothing to do with a real
/// regression. `DashboardSnapshotTests` already reasons about this exact class of live-`Date()` jitter
/// and budgets `precision: 0.99, perceptualPrecision: 0.98`; applying the SAME tolerance here (rather
/// than freezing "now") keeps this test consistent with that precedent while still catching a REAL
/// structural regression (a moved/missing row, wrong color, or layout break differs by orders of
/// magnitude more than a one-digit text jitter).
///
/// `SettingsView` requires an injected `@Environment(ModeStore.self)` (the P14 S3 mode selector row).
/// `ModeStore`'s designated `init(defaults:settings:)` is the injectable, side-effect-isolated
/// constructor tests use (mirrors `ModeStoreTests`/`PumpOnboardingFlowTests`) — a fresh, per-test
/// `UserDefaults` suite keeps this test from sharing state with `ModeStore.shared` or any other test.
@MainActor
@Suite struct SettingsSnapshotTests {
    /// A private UserDefaults suite for ModeStore's earned/onboarded keys — mirrors
    /// `ModeStoreTests.freshDefaults()` so this snapshot fixture never shares mode state with
    /// `ModeStore.shared` or any other test.
    private func freshModeStore() -> ModeStore {
        let name = "settings-snapshot-modestore-\(UUID().uuidString)"
        return ModeStore(defaults: UserDefaults(suiteName: name)!, settings: .shared)
    }

    @Test func settingsCompactWidthRootCategoryListQueryEmpty() async {
        let backend = MockBackend()
        // Deviation (Rule 3, mirrors DashboardSnapshotTests): a deterministic fixture so the
        // rendered content (status row / connection state feeding into the settings screen's
        // environment) doesn't vary run-to-run.
        backend.seedDeterministicGlucoseForTesting()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-snapshot-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        await model.connect()

        let view = SettingsView(model: model)
            .environment(freshModeStore())
        assertSnapshot(of: view, as: .image(precision: 0.99, perceptualPrecision: 0.98, layout: .sizeThatFits))
    }
}
