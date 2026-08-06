import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P14 S8 (§2.1(2)): the one-time clinician-tier acknowledgment is PERSISTED and IDEMPOTENT, and it is
/// NON-BLOCKING — it records that clinical ownership was disclosed but never gates a write (it is NOT a
/// `DenialReason` and NOT the every-time `UnverifiedFeatureGate`).
@Suite(.serialized)
@MainActor
struct ClinicianTierAckTests {

    @Test func acknowledgmentPersistsOnceAndIsIdempotent() {
        let s = AppSettings.shared
        let saved = s.clinicianTierAckAt
        defer { s.clinicianTierAckAt = saved }

        s.clinicianTierAckAt = nil
        #expect(!s.hasAcknowledgedClinicianTier)
        s.acknowledgeClinicianTier()
        #expect(s.hasAcknowledgedClinicianTier)
        let first = s.clinicianTierAckAt
        s.acknowledgeClinicianTier()                 // idempotent — keeps the first timestamp
        #expect(s.clinicianTierAckAt == first)
    }

    @Test func clinicianTierWriteIsNotBlockedByAMissingAcknowledgment() async {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, adv = s.advancedControlEnabled, ack = s.clinicianTierAckAt
        defer { s.phoneReadOnly = ro; s.childModeEnabled = child; s.advancedControlEnabled = adv; s.clinicianTierAckAt = ack }
        s.phoneReadOnly = false; s.childModeEnabled = false; s.advancedControlEnabled = true
        s.clinicianTierAckAt = nil                    // deliberately NOT acknowledged

        let backend = MockBackend()                   // Mobi, .mobiAdvanced
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("s8-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: url)
        await backend.connect()

        #expect(!s.hasAcknowledgedClinicianTier)
        #expect(GatedPumpWrite.setMaxBolus.requiredTier == .clinician)   // it IS a clinician-tier write
        await model.setMaxBolus(units: 10)
        // …and it still reaches the pump with no acknowledgment present — the ack is a disclosure, not a lock.
        #expect(backend.snapshot.maxBolusUnits == 10)
    }
}
