import Testing
import Foundation
import SnapshotTesting
@testable import faBolus

/// Visual pin of compact Settings so Safety/Privacy rows cannot silently vanish; perceptual
/// tolerance absorbs live CGM-age text jitter, not a structural regression.
@MainActor
@Suite struct SettingsSnapshotTests {
    /// A private UserDefaults suite for ModeStore's onboarding keys so this snapshot fixture never
    /// shares state with `ModeStore.shared` or any other test.
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
