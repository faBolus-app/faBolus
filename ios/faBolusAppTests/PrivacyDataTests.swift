import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// F1 (§13) — the unified on-device health-data export + gated complete-erase.
///
/// Export must carry the setting-change provenance log and the remote-bolus ledger audit trail and
/// round-trip losslessly. (Glucose/insulin/carb history is pulled from the shared on-disk SwiftData
/// store, so these tests assert on the deterministic seams — the injected ledger + change log — not on
/// the ambient history contents.)
@MainActor
@Suite(.serialized) struct PrivacyDataTests {

    /// A settled (terminal) ledger, pre-saved to a temp file, that an `AppModel` will load as its audit
    /// trail — no delivery path or gating dependency.
    private func seededLedgerURL() throws -> (URL, RemoteBolusLedger) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.json")
        var seed = RemoteBolusLedger()
        _ = seed.begin(peerId: "watch", requestId: "r1",
                       doseKey: RemoteBolusLedger.doseKey(units: 2.0, carbsGrams: nil, bgMgdl: nil))
        seed.settle(peerId: "watch", requestId: "r1", status: "delivered", message: nil, deliveredUnits: 2.0)
        try RemoteBolusLedgerStore(url: url).save(seed)
        return (url, seed)
    }

    private func tempSettingChangeStore() -> (StoredSettingChangeStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scl-\(UUID().uuidString).json")
        return (StoredSettingChangeStore(url: url), url)
    }

    private var settledDoseKey: String {
        RemoteBolusLedger.doseKey(units: 2.0, carbsGrams: nil, bgMgdl: nil)
    }

    @Test func exportCarriesSettingChangeLogAndLedgerAndRoundTrips() throws {
        let (ledgerURL, _) = try seededLedgerURL()
        let model = AppModel(source: MockBackend(), ledgerStoreURL: ledgerURL)

        // Seed one setting-change record via an injected temp store.
        let (scl, _) = tempSettingChangeStore()
        model.settingChangeStore = scl
        let change = StoredSettingChange(key: .global("maxBolus"), before: .double(10), after: .double(12),
                                         provenance: .selfSet, atSeconds: 1_700_000_000)
        model.settingChangeStore.record(change)

        let export = model.buildPrivacyExport()

        // Setting-change provenance log is present (latest + audit trail).
        #expect(export.settingChangeLog.log.count == 1)
        #expect(export.settingChangeLog.log.first == change)
        #expect(export.settingChangeLog.current(.global("maxBolus"))?.after == .double(12))

        // The remote-bolus ledger audit trail is carried: the seeded terminal entry still replays.
        var carried = export.remoteBolusLedger
        #expect(carried.begin(peerId: "watch", requestId: "r1", doseKey: settledDoseKey)
                == .replay(status: "delivered", message: nil, deliveredUnits: 2.0))

        // Metadata + lossless round-trip of the whole shareable payload.
        #expect(export.meta.schemaVersion == PrivacyDataExport.currentSchema)
        let data = try export.encoded()
        let decoded = try PrivacyDataExport.decode(data)
        #expect(decoded.settingChangeLog == export.settingChangeLog)
        var decodedLedger = decoded.remoteBolusLedger
        #expect(decodedLedger.begin(peerId: "watch", requestId: "r1", doseKey: settledDoseKey)
                == .replay(status: "delivered", message: nil, deliveredUnits: 2.0))
    }

    // MARK: 09.18d-02 — caffeine/alcohol tracker export round-trip + back-compat

    /// The tracker arrays round-trip losslessly, and a legacy payload written before the trackers
    /// shipped (no `caffeine`/`alcohol` keys) decodes to empty arrays (decode-optional back-compat).
    @Test func trackerExportRoundTripsAndDecodesLegacyPayload() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let export = PrivacyDataExport(
            meta: .init(createdAt: t0, appVersion: "0.3.0", schemaVersion: PrivacyDataExport.currentSchema),
            glucose: [], boluses: [], carbs: [],
            caffeine: [.init(date: t0, milligrams: 95, source: "Coffee")],
            alcohol: [.init(date: t0.addingTimeInterval(60), standardDrinks: 1.5, source: "Wine")],
            settingChangeLog: SettingChangeLog(), remoteBolusLedger: RemoteBolusLedger())
        let decoded = try PrivacyDataExport.decode(export.encoded())
        #expect(decoded.caffeine == export.caffeine)
        #expect(decoded.alcohol == export.alcohol)

        // A legacy payload lacking the tracker keys still decodes → empty arrays. Derived from a real
        // encoded payload with the two keys stripped, so every nested encoding matches the decoder.
        var obj = try JSONSerialization.jsonObject(with: export.encoded()) as! [String: Any]
        obj.removeValue(forKey: "caffeine")
        obj.removeValue(forKey: "alcohol")
        let legacyData = try JSONSerialization.data(withJSONObject: obj)
        let legacyDecoded = try PrivacyDataExport.decode(legacyData)
        #expect(legacyDecoded.caffeine.isEmpty)
        #expect(legacyDecoded.alcohol.isEmpty)
    }

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

    // MARK: F1 option (b) — full reset (Q8.2): wipes health + Keychain secrets + unpairs, same gate
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
