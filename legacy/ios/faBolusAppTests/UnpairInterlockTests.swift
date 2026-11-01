import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P14 S12 (§2.2.3): the unpair confirmation text resolves from the connected pump's model — a Mobi
/// carries the unconditional charging-base warning; a t:slim does not.
@Suite(.serialized)
@MainActor
struct UnpairInterlockTests {

    private func makeModel(isMobi: Bool) async -> AppModel {
        let backend = MockBackend(isMobi: isMobi)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("s12-\(UUID().uuidString).json")
        let m = AppModel(source: backend, ledgerStoreURL: url)
        await backend.connect()
        return m
    }

    @Test func mobiUnpairWarnsAboutTheChargingBase() async {
        let m = await makeModel(isMobi: true)
        #expect(m.lastKnownPumpModel == .mobi)
        #expect(m.unpairConfirmation.localizedCaseInsensitiveContains("charging base"))
    }

    @Test func tslimUnpairDoesNotWarnAboutTheBase() async {
        let m = await makeModel(isMobi: false)
        #expect(m.lastKnownPumpModel == .tslimX2)
        #expect(!m.unpairConfirmation.localizedCaseInsensitiveContains("charging base"))
    }
}
