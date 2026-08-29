import Testing
import Foundation
import SnapshotTesting
@testable import faBolus

/// Pins the compact-width BolusEntryView snapshot so a readable-width cap on iPad cannot silently change the iPhone layout.
@MainActor
@Suite struct BolusEntrySnapshotTests {
    @Test func bolusEntryCompactWidthEmbeddedDefaultEmpty() async {
        let backend = MockBackend()
        // Deterministic fixture so status/connection feeding the calculator doesn't vary run-to-run.
        backend.seedDeterministicGlucoseForTesting()
        // Dedicated ledger file so this AppModel never shares a durable-ledger path with another test.
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bolus-entry-snapshot-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        await model.connect()

        let view = BolusEntryView(model: model, embedded: true)
        assertSnapshot(of: view, as: .image(layout: .sizeThatFits))
    }
}
