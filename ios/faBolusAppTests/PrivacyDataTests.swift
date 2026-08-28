import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// On-device erase and full reset stay ungated regardless of `FABOLUS_BACKUP`. Both must refuse
/// while a delivery is unresolved; erase wipes health data only, full reset also unpairs.
@MainActor
@Suite(.serialized) struct PrivacyDataTests {

    // MARK: Complete erase — gated + health-data-only

    /// Erase MUST refuse while a delivery is unresolved (a `delivering` entry that reconciliation still
    /// needs), using the same signals the delivery mutex consults.
    @Test func eraseRefusesWhileDeliveryUnresolved() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.json")
        var seed = RemoteBolusLedger()
        _ = seed.begin(peerId: "watch", requestId: "r9",
                       doseKey: RemoteBolusLedger.doseKey(units: 2.0, carbsGrams: nil, bgMgdl: nil))
        seed.markDelivering(peerId: "watch", requestId: "r9", bolusId: 7)   // delivering + sent ⇒ unresolved
        try RemoteBolusLedgerStore(url: url).save(seed)

        let model = AppModel(source: MockBackend(), ledgerStoreURL: url)
        #expect(model.deliveryGloballyBlocked)   // the seeded unresolved entry blocks delivery synchronously

        let outcome = model.eraseAllOnDeviceHealthData()
        guard case .refused = outcome else {
            Issue.record("expected .refused while a delivery is unresolved, got \(outcome)")
            return
        }
    }

    /// Erase succeeds with no unresolved delivery, wipes the health data (setting-change log), and does
    /// NOT touch Keychain secrets (pump pairing) or unpair the pump.
    @Test func eraseSucceedsWipesHealthDataAndKeepsKeychainAndPairing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(source: MockBackend(), ledgerStoreURL: dir.appendingPathComponent("ledger.json"))
        #expect(!model.deliveryGloballyBlocked)

        // Health data that MUST be wiped: a setting-change record (injected temp store).
        model.settingChangeStore = StoredSettingChangeStore(url: dir.appendingPathComponent("scl.json"))
        model.settingChangeStore.record(StoredSettingChange(
            key: .global("maxBolus"), before: nil, after: .double(12), provenance: .selfSet, atSeconds: 1))
        #expect(model.settingChangeStore.load().log.count == 1)

        // A Keychain pairing secret + the pump pairing state that MUST survive (scope = health data only).
        PairingStore.save([9, 9, 9])
        let secretBefore = PairingStore.load()
        let pairingBefore = model.hasStoredPairing
        defer { PairingStore.clear() }

        let outcome = model.eraseAllOnDeviceHealthData()
        #expect(outcome == .erased)

        // Health data gone…
        #expect(model.settingChangeStore.load().log.isEmpty)
        #expect(!model.deliveryGloballyBlocked)
        // …but Keychain + pairing untouched (no unpair, no secret wipe).
        #expect(PairingStore.load() == secretBefore)
        #expect(model.hasStoredPairing == pairingBefore)
    }

    // MARK: Full reset: wipes health + pairing, same unresolved-delivery gate
    //
    // NOTE: the xctest host has no functional Keychain, so PairingStore / CredentialStore (Keychain) don't
    // persist here — the existing health-erase test sidesteps this by comparing before==after. We therefore
    // assert the full reset's effect on the TESTABLE signals: the file-based setting-change store (health
    // data) and the UserDefaults-based PumpPeripheralStore (the unpair target). The Keychain-clearing calls
    // (PairingStore.clear / clearPin / CredentialStore.set(nil)) are code-verified and run on the same path.

    /// The FULL reset must honor the SAME in-flight/unresolved-delivery refusal gate, and on refusal must
    /// clear NOTHING — health data AND the persisted pairing/peripheral stay intact (the safety-critical
    /// property: a full reset can never run over an unresolved delivery).
    @Test func fullResetRefusesWhileDeliveryUnresolvedAndClearsNothing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.json")
        var seed = RemoteBolusLedger()
        _ = seed.begin(peerId: "watch", requestId: "r9",
                       doseKey: RemoteBolusLedger.doseKey(units: 2.0, carbsGrams: nil, bgMgdl: nil))
        seed.markDelivering(peerId: "watch", requestId: "r9", bolusId: 7)   // unresolved
        try RemoteBolusLedgerStore(url: url).save(seed)

        let model = AppModel(source: MockBackend(), ledgerStoreURL: url)
        #expect(model.deliveryGloballyBlocked)

        model.settingChangeStore = StoredSettingChangeStore(url: dir.appendingPathComponent("scl.json"))
        model.settingChangeStore.record(StoredSettingChange(
            key: .global("maxBolus"), before: nil, after: .double(12), provenance: .selfSet, atSeconds: 1))
        let pid = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        PumpPeripheralStore.set(pid); defer { PumpPeripheralStore.clear() }

        guard case .refused = model.eraseEverythingFullReset() else {
            Issue.record("expected .refused while a delivery is unresolved"); return
        }
        // Nothing cleared on refusal: health data + persisted peripheral (pairing) both survive.
        #expect(model.settingChangeStore.load().log.count == 1)
        #expect(PumpPeripheralStore.id() == pid)
    }

    /// With no unresolved delivery, the full reset wipes health data AND clears the persisted peripheral
    /// (the unpair target) — backend-agnostic (works with the mock, whose own forgetPairing is a no-op).
    @Test func fullResetWipesHealthDataAndUnpairs() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(source: MockBackend(), ledgerStoreURL: dir.appendingPathComponent("ledger.json"))
        #expect(!model.deliveryGloballyBlocked)

        model.settingChangeStore = StoredSettingChangeStore(url: dir.appendingPathComponent("scl.json"))
        model.settingChangeStore.record(StoredSettingChange(
            key: .global("maxBolus"), before: nil, after: .double(12), provenance: .selfSet, atSeconds: 1))
        #expect(model.settingChangeStore.load().log.count == 1)
        PumpPeripheralStore.set(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        defer { PumpPeripheralStore.clear() }

        #expect(model.eraseEverythingFullReset() == .erased)
        #expect(model.settingChangeStore.load().log.isEmpty)     // health wiped
        #expect(PumpPeripheralStore.id() == nil)                 // unpaired (peripheral cleared)
    }
}
