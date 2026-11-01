import Testing
import Foundation
@testable import faBolusCore

/// A settled reconciliation must be announced once and then stop. The per-request notification key
/// family has one constructor and a recognizer, so it can be withdrawn by name. The announce-once rule
/// itself lives in the alert engine (`AlertsTests.RelaunchTests`), which follows the ledger instead of a
/// replay log.
@Suite struct SettledReconciliationDoesNotReplayTests {
    typealias B = NotificationBroker
    typealias C = NotificationBroker.Category

    // MARK: - The dynamic key family now has a name

    /// Byte-identical to the literal the two post sites used before this change — an on-device entry
    /// written by an older build must still be recognized.
    @Test func theReconciliationDedupeKeyIsUnchangedAndRecognizable() {
        let key = RemoteBolusLedger.reconciliationDedupeKey(peerId: "garmin", requestId: "req-1")
        #expect(key == "reconcile-garmin-req-1")
        #expect(RemoteBolusLedger.isReconciliationDedupeKey(key))
        #expect(RemoteBolusLedger.isReconciliationDedupeKey("reconcile-local-abc"))
    }

    /// The recognizer must not claim the OTHER durable safety keys — an over-broad match would let a
    /// reconciliation-scoped prune delete a pump-disconnect or CGM entry.
    @Test func theRecognizerNeverMatchesAnotherSafetyCategorysKeys() {
        for other in [
            "safety.pumpDisconnect", "safety.cgmDataLoss", "safety.pumpConnectionUnstable",
            "safety.cgmStalenessWatchdog", "safety.pumpDisconnect.escalation.30m",
            "bolusDeliveryFailed-3", "indeterminate-widget-req-1", ""
        ] {
            #expect(!RemoteBolusLedger.isReconciliationDedupeKey(other), "must not match \(other)")
        }
    }
}
