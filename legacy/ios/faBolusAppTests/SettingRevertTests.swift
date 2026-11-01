import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// §2.1(4) B1(c): the consensus-default auto-snapshot baseline. Drives the REAL AppModel profile-segment
/// read against a connected Mobi `MockBackend` with an injected setting-change store. Pins: a first
/// profile-segment read records an explicit `.consensusDefault` baseline per field, idempotently, without
/// polluting the visible audit trail. Mirrors `ProfileSegmentProvenanceTests`' gate setup.
///
/// The one-tap revert this file used to cover (`AppModel.revertSetting`/`revertSegmentField`) was retired
/// with `AccessPolicy` Gate 1: every write it could revert (`setMaxBolus`/`setMaxBasal`/
/// `modifyProfileSegment`) went with the ack-gated funnel, so revert's every switch arm had collapsed to
/// its `default` "can't be reverted" branch — a function whose every branch refuses is accretion, not a
/// feature. `AppModel.revertSetting` and `revertSegmentField` were deleted whole in that same commit.
@Suite(.serialized) @MainActor
struct SettingRevertTests {
    private func makeModel() async -> (AppModel, MockBackend, StoredSettingChangeStore) {
        let s = AppSettings.shared
        s.phoneReadOnly = false
        s.childModeEnabled = false
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
}
