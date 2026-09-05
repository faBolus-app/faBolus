import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// §2.1(4) B1(c): the consensus-default auto-snapshot baseline + one-tap revert. Drives the REAL AppModel
/// gated therapy-write path against a connected Mobi `MockBackend` with an injected setting-change store.
/// Pins: (1) a first profile-segment read records an explicit `.consensusDefault` baseline per field,
/// idempotently, without polluting the visible audit trail; (2) reverting a setting re-applies its
/// previous value THROUGH the gated funnel (so the ack + capability + read-only gates all still apply) and
/// records the revert honestly as a new change; (3) revert refuses — with a reason, no pump write — when
/// there is nothing to revert or the segment is gone. Mirrors `ProfileSegmentProvenanceTests`' gate setup.
@Suite(.serialized) @MainActor
struct SettingRevertTests {
    private func makeModel() async -> (AppModel, MockBackend, StoredSettingChangeStore) {
        let s = AppSettings.shared
        s.phoneReadOnly = false
        s.childModeEnabled = false
        s.appMode = .advanced
        let backend = MockBackend()  // Mobi / .mobiAdvanced
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "b1c-l-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "b1c-s-\(UUID().uuidString).json")
        model.settingChangeStore = StoredSettingChangeStore(url: storeURL)
        await backend.connect()
        return (model, backend, model.settingChangeStore)
    }

    // MARK: Auto-snapshot baseline

    @Test func firstProfileReadRecordsConsensusBaselinePerFieldIdempotently() async {
        let (model, _, store) = await makeModel()
        await model.refreshProfileSegments(idpId: 0)  // mock seeds one segment @ start 0
        for field in ["basalRate", "carbRatio", "isf", "targetBg"] {
            let key = SettingKey.segment(idpId: 0, startMinutes: 0, field: field)
            #expect(store.load().provenance(key) == .consensusDefault)  // explicit origin
            #expect(store.load().current(key)?.before == nil)  // a pure baseline: nothing to revert to
        }
        #expect(store.load().log.isEmpty)  // baselines never enter the audit trail
        let latestCount = store.load().latest.count
        // Re-read: idempotent — no new baselines, no duplication.
        await model.refreshProfileSegments(idpId: 0)
        #expect(store.load().latest.count == latestCount)
        #expect(store.load().log.isEmpty)
    }

    @Test func aRealEditSupersedesTheBaselineAndIsNotReBaselined() async {
        let (model, _, store) = await makeModel()
        await model.refreshProfileSegments(idpId: 0)
        model.acknowledgeUnverifiedTherapy()
        await model.modifyProfileSegment(
            idpId: 0, segmentIndex: 0, startTimeMinutes: 0,
            basalRateUnitsPerHour: 1.25, carbRatioGramsPerUnit: 10, isf: 40, targetBg: 110)
        #expect(model.lastError == nil)
        let key = SettingKey.segment(idpId: 0, startMinutes: 0, field: "basalRate")
        #expect(store.load().provenance(key) == .selfSet)
        // A subsequent profile re-read must NOT clobber the .selfSet edit back to a consensus baseline.
        await model.refreshProfileSegments(idpId: 0)
        #expect(store.load().provenance(key) == .selfSet)
    }

    // MARK: Revert — global scalar

    @Test func revertMaxBolusReAppliesPreviousValueThroughTheGatedFunnel() async {
        let (model, backend, store) = await makeModel()
        model.acknowledgeUnverifiedTherapy()
        await model.setMaxBolus(units: 8)
        model.acknowledgeUnverifiedTherapy()
        await model.setMaxBolus(units: 12)
        #expect(model.snapshot.maxBolusUnits == 12)
        let writesBefore = backend.controlWriteCount
        // Revert → re-applies 8 (the latest change's `before`) and records a new change (12 → 8).
        model.acknowledgeUnverifiedTherapy()
        await model.revertSetting(.global("maxBolus"))
        #expect(model.lastError == nil)
        #expect(model.snapshot.maxBolusUnits == 8)
        #expect(backend.controlWriteCount == writesBefore + 1)  // it DID write through the funnel
        let cur = store.load().current(.global("maxBolus"))
        #expect(cur?.before == .double(12) && cur?.after == .double(8))  // revert honestly recorded
    }

    @Test func revertRefusesWhenNothingToRevert() async {
        let (model, backend, _) = await makeModel()
        let writesBefore = backend.controlWriteCount
        model.acknowledgeUnverifiedTherapy()
        await model.revertSetting(.global("maxBolus"))  // no prior change on record
        #expect(model.lastError?.contains("hasn't been changed") == true)
        #expect(backend.controlWriteCount == writesBefore)  // no pump write
    }

    // MARK: Revert — profile segment field

    @Test func revertSegmentFieldReAppliesPreviousValue() async {
        let (model, _, store) = await makeModel()
        await model.refreshProfileSegments(idpId: 0)  // basalRate baseline 0.8
        model.acknowledgeUnverifiedTherapy()
        await model.modifyProfileSegment(
            idpId: 0, segmentIndex: 0, startTimeMinutes: 0,
            basalRateUnitsPerHour: 1.4, carbRatioGramsPerUnit: 10, isf: 40, targetBg: 110)
        #expect(model.snapshot.viewedProfileSegments.first?.basalRateUnitsPerHour == 1.4)
        model.acknowledgeUnverifiedTherapy()
        await model.revertSetting(.segment(idpId: 0, startMinutes: 0, field: "basalRate"))
        #expect(model.lastError == nil)
        #expect(model.snapshot.viewedProfileSegments.first?.basalRateUnitsPerHour == 0.8)  // reverted on the pump
        let cur = store.load().current(.segment(idpId: 0, startMinutes: 0, field: "basalRate"))
        #expect(cur?.before == .double(1.4) && cur?.after == .double(0.8))  // new change recorded
    }

    // MARK: Provenance-parity characterization
    //
    // Pins the provenance rows a scripted edit sequence (change, no-op change, failed change)
    // produces AGAINST CURRENT CODE, before `ClinicianEditProvenanceRecorder` is extracted out of
    // `AppModel`. `recordClinicianEditIfChanged` currently guards on `lastError == nil` (read live
    // off `AppModel`); the failed-change case below exercises exactly that branch via a REAL gate
    // denial (skipping `acknowledgeUnverifiedTherapy()`), not a mock — so this characterizes the
    // actual funnel behavior, not an assumption about it.
    @Test func scriptedEditSequenceProvenanceRowsMatchCurrentBehavior() async {
        let (model, backend, store) = await makeModel()
        let key = SettingKey.global("maxBolus")

        // 1) A real, value-changing edit -> a NEW `.selfSet` row with the correct before/after.
        model.acknowledgeUnverifiedTherapy()
        await model.setMaxBolus(units: 8)
        #expect(model.lastError == nil)
        #expect(model.snapshot.maxBolusUnits == 8)
        let afterFirstEdit = store.load().current(key)
        #expect(afterFirstEdit?.provenance == .selfSet)
        #expect(afterFirstEdit?.after == .double(8))
        let logCountAfterFirstEdit = store.load().log.count
        #expect(logCountAfterFirstEdit >= 1)

        // 2) A NO-OP change (write succeeds, but requested value == current value) -> before == after,
        //    so nothing new is recorded — the latest row and the audit-trail length are unchanged.
        model.acknowledgeUnverifiedTherapy()
        await model.setMaxBolus(units: 8)
        #expect(model.lastError == nil)
        #expect(store.load().log.count == logCountAfterFirstEdit)
        #expect(store.load().current(key)?.after == .double(8))

        // 3) A FAILED change: skip `acknowledgeUnverifiedTherapy()` so the gated-therapy ack check
        //    denies the write BEFORE it reaches the backend, setting `lastError`. Even though the
        //    requested value (15) differs from the current one (8), `recordClinicianEditIfChanged`
        //    must record NOTHING for a failed write.
        let writesBefore = backend.controlWriteCount
        await model.setMaxBolus(units: 15)
        #expect(model.lastError != nil)
        #expect(backend.controlWriteCount == writesBefore)  // no pump write attempted
        #expect(model.snapshot.maxBolusUnits == 8)  // unchanged
        #expect(store.load().current(key)?.after == .double(8))  // provenance UNCHANGED
        #expect(store.load().log.count == logCountAfterFirstEdit)  // no new row for the failed write
    }

    @Test func revertRefusesWhenSegmentNoLongerOnPump() async {
        let (model, backend, _) = await makeModel()
        await model.refreshProfileSegments(idpId: 0)  // seeds start 0 (index 0)
        // Add a distinct segment at 12:00 so it stays gone after delete (the mock reseeds only start-0 when empty).
        model.acknowledgeUnverifiedTherapy()
        await model.addProfileSegment(
            idpId: 0, startTimeMinutes: 720,
            basalRateUnitsPerHour: 1.2, carbRatioGramsPerUnit: 10, isf: 40, targetBg: 110)
        guard let added = model.snapshot.viewedProfileSegments.first(where: { $0.startTimeMinutes == 720 }) else {
            Issue.record("added segment not present")
            return
        }
        model.acknowledgeUnverifiedTherapy()
        await model.modifyProfileSegment(
            idpId: 0, segmentIndex: added.segmentIndex, startTimeMinutes: 720,
            basalRateUnitsPerHour: 1.4, carbRatioGramsPerUnit: 10, isf: 40, targetBg: 110)
        model.acknowledgeUnverifiedTherapy()
        await model.deleteProfileSegment(idpId: 0, segmentIndex: added.segmentIndex)  // 12:00 segment gone
        let writesBefore = backend.idpWriteCount
        model.acknowledgeUnverifiedTherapy()
        await model.revertSetting(.segment(idpId: 0, startMinutes: 720, field: "basalRate"))
        #expect(model.lastError?.contains("no longer on the pump") == true)
        #expect(backend.idpWriteCount == writesBefore)  // no modify write attempted
    }
}
