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
        s.acknowledgeClinicianTier()  // idempotent — keeps the first timestamp
        #expect(s.clinicianTierAckAt == first)
    }
}
