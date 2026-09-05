import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// §2.1(2) / plan Q2.1: a Personal-Profile SEGMENT edit records per-field `.selfSet` provenance in the S7
/// store — the gap where only the 3 global settings (maxBolus / maxBasal / controlIQ) recorded provenance
/// while the basal / carb-ratio / ISF / target the pump actually doses from recorded nothing (task #109
/// was marked complete but the profile params were unwired). Keyed on the segment START TIME (stable
/// identity across index renumbering). Mirrors `ClinicianTierAckTests`' gate setup.
@Suite(.serialized) @MainActor
struct ProfileSegmentProvenanceTests {
    private func openGatesAndMakeModel() async -> (AppModel, MockBackend, StoredSettingChangeStore) {
        let s = AppSettings.shared
        s.phoneReadOnly = false
        s.childModeEnabled = false
        s.appMode = .advanced
        let backend = MockBackend()  // Mobi / .mobiAdvanced
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "s21l-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "s21p-\(UUID().uuidString).json")
        model.settingChangeStore = StoredSettingChangeStore(url: storeURL)
        await backend.connect()
        model.acknowledgeUnverifiedTherapy()  // satisfy the untested-feature ack (S6); provenance is S8/§2.1(2)
        return (model, backend, model.settingChangeStore)
    }

    @Test func modifyProfileSegmentRecordsChangedFieldsOnly() async {
        let (model, _, store) = await openGatesAndMakeModel()
        await model.refreshProfileSegments(idpId: 0)  // mock seeds a default segment at index 0 / start 0
        guard let seg = model.snapshot.viewedProfileSegments.first(where: { $0.segmentIndex == 0 }) else {
            Issue.record("mock did not seed a viewed segment")
            return
        }
        // Change ONLY the basal rate; keep CR / ISF / target the same.
        await model.modifyProfileSegment(
            idpId: 0, segmentIndex: 0, startTimeMinutes: seg.startTimeMinutes,
            basalRateUnitsPerHour: seg.basalRateUnitsPerHour + 0.15,
            carbRatioGramsPerUnit: seg.carbRatioGramsPerUnit,
            isf: seg.isf, targetBg: seg.targetBg)
        #expect(model.lastError == nil)
        let r = store.load()
        // The changed field is recorded as .selfSet, and it IS a real entry in the audit trail…
        #expect(r.provenance(.segment(idpId: 0, startMinutes: seg.startTimeMinutes, field: "basalRate")) == .selfSet)
        #expect(!r.history(.segment(idpId: 0, startMinutes: seg.startTimeMinutes, field: "basalRate")).isEmpty)
        // …the UNCHANGED fields are the B1(c) consensus-default BASELINE (present in `latest` so a revert
        // anchor exists, but with NO real change in the visible audit trail — the value-changed guard).
        for field in ["isf", "carbRatio", "targetBg"] {
            let key = SettingKey.segment(idpId: 0, startMinutes: seg.startTimeMinutes, field: field)
            #expect(r.provenance(key) == .consensusDefault)
            #expect(r.current(key)?.before == nil)  // a pure baseline: nothing to revert to
            #expect(r.history(key).isEmpty)  // not a change → not in the audit log
        }
    }

    @Test func addProfileSegmentRecordsAllFourFieldsAsSelfSet() async {
        let (model, _, store) = await openGatesAndMakeModel()
        await model.refreshProfileSegments(idpId: 0)
        await model.addProfileSegment(
            idpId: 0, startTimeMinutes: 720,
            basalRateUnitsPerHour: 1.2, carbRatioGramsPerUnit: 8, isf: 45, targetBg: 110)
        #expect(model.lastError == nil)
        let r = store.load()
        for field in ["basalRate", "carbRatio", "isf", "targetBg"] {
            #expect(
                r.provenance(.segment(idpId: 0, startMinutes: 720, field: field)) == .selfSet,
                "\(field) of a new segment must record .selfSet provenance")
        }
    }

    // MARK: - B1(a): the editor's per-field provenance badge lookup

    /// `segmentFieldProvenance` feeds the editor badge: an edited field reads `.selfSet`, an untouched one
    /// falls back to `.consensusDefault` (absence == consensus default). Never nil here (store is healthy).
    @Test func segmentFieldProvenanceReflectsEditsAndDefaultsTheRest() async {
        let (model, _, _) = await openGatesAndMakeModel()
        await model.refreshProfileSegments(idpId: 0)
        guard let seg = model.snapshot.viewedProfileSegments.first(where: { $0.segmentIndex == 0 }) else {
            Issue.record("mock did not seed a viewed segment")
            return
        }
        await model.modifyProfileSegment(
            idpId: 0, segmentIndex: 0, startTimeMinutes: seg.startTimeMinutes,
            basalRateUnitsPerHour: seg.basalRateUnitsPerHour + 0.15,
            carbRatioGramsPerUnit: seg.carbRatioGramsPerUnit,
            isf: seg.isf, targetBg: seg.targetBg)
        let prov = model.segmentFieldProvenance(idpId: 0, startMinutes: seg.startTimeMinutes)
        #expect(prov != nil)  // healthy store → not nil
        #expect(prov?["basalRate"] == .selfSet)  // the edited field
        #expect(prov?["carbRatio"] == .consensusDefault)  // untouched → consensus default
        #expect(prov?["isf"] == .consensusDefault)
        #expect(prov?["targetBg"] == .consensusDefault)
    }

    /// The non-color badge cue: every provenance has a distinct, non-empty SF-symbol name (WCAG parity
    /// with the F4 band channel).
    @Test func everyProvenanceHasADistinctSymbol() {
        let all = SettingProvenance.allCases
        let symbols = all.map(\.symbolName)
        #expect(Set(symbols).count == all.count)
        #expect(symbols.allSatisfy { !$0.isEmpty })
    }
}
