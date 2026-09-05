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

    @Test func clinicianTierWriteIsNotBlockedByAMissingAcknowledgment() async {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled,
            ack = s.clinicianTierAckAt, mode = s.appMode
        defer {
            s.phoneReadOnly = ro
            s.childModeEnabled = child
            s.clinicianTierAckAt = ack
            s.appMode = mode
        }
        s.phoneReadOnly = false
        s.childModeEnabled = false
        s.appMode = .advanced  // setMaxBolus is an Advanced-mode write (P14 S2 gate)
        s.clinicianTierAckAt = nil  // deliberately NOT acknowledged

        let backend = MockBackend()  // Mobi, .mobiAdvanced
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("s8-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: url)
        await backend.connect()

        #expect(!s.hasAcknowledgedClinicianTier)
        #expect(GatedPumpWrite.setMaxBolus.requiredTier == .clinician)  // it IS a clinician-tier write
        // S6 routes setMaxBolus through the untested-feature ack funnel (runGatedTherapy); ack THAT so we
        // isolate the CLINICIAN-tier axis (S8). The clinician ack stays absent below.
        model.acknowledgeUnverifiedTherapy()
        await model.setMaxBolus(units: 10)
        // …and it still reaches the pump with the CLINICIAN acknowledgment absent — that ack is a
        // disclosure, not a lock (distinct from the untested-feature ack, which S6 does enforce).
        #expect(backend.snapshot.maxBolusUnits == 10)
    }

    /// §2.1(2)(3)(4): a successful clinician-tier edit is RECORDED as `.selfSet` provenance (with a
    /// before/after revert target) in the S7 store; a BLOCKED edit records nothing.
    @Test func clinicianTierEditRecordsSelfSetProvenanceOnlyOnSuccess() async {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, mode = s.appMode
        defer {
            s.phoneReadOnly = ro
            s.childModeEnabled = child
            s.appMode = mode
        }
        s.phoneReadOnly = false
        s.childModeEnabled = false
        s.appMode = .advanced  // setMaxBolus is an Advanced-mode write (P14 S2 gate)

        let backend = MockBackend()  // Mobi
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "s8l-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "s8p-\(UUID().uuidString).json")
        model.settingChangeStore = StoredSettingChangeStore(url: storeURL)
        let store = model.settingChangeStore
        await backend.connect()

        // Successful edit → one `.selfSet` record with the exact before/after (the revert target).
        // Satisfy S6's untested-feature ack (runGatedTherapy) so the write proceeds; provenance is S8's.
        let before = backend.snapshot.maxBolusUnits
        model.acknowledgeUnverifiedTherapy()
        await model.setMaxBolus(units: 10)
        #expect(model.lastError == nil)
        let rec = store.load().current(.global("maxBolus"))
        #expect(rec?.provenance == .selfSet)
        #expect(rec?.before == .double(before))
        #expect(rec?.after == .double(10))

        // A BLOCKED edit records nothing: flip phone read-only → the write is denied, so the
        // stored record stays the previous one (no `.selfSet` for an edit that never reached the pump).
        s.phoneReadOnly = true
        await model.setMaxBolus(units: 7)
        #expect(model.lastError != nil)
        #expect(store.load().current(.global("maxBolus"))?.after == .double(10))
    }
}
