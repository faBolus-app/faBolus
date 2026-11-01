import DexcomBLE
import Foundation
import Testing
import faBolusCore

@testable import GlucoseSources

@Suite("Glucose source registry")
struct GlucoseSourceRegistryTests {
    func registry() -> GlucoseSourceRegistry {
        GlucoseSourceRegistry(settings: isolatedSettings(), secrets: InMemorySecretStore())
    }

    @Test("the registry holds Dexcom Share, G6 and G7, and nothing removed comes back")
    func sources() {
        let ids = registry().descriptors.map(\.id)
        #expect(ids == ["dexcom-share", "dexcom-g6", "dexcom-g7"])
        for removed in ["librelinkup", "xdrip-appgroup", "nightscout", "healthkit", "dexcom-g6-ble", "dexcom-g7-ble"] {
            #expect(registry().descriptor(id: removed) == nil, "\(removed)")
        }
    }

    @Test("every source classifies how it connects")
    func connectionKinds() {
        let registry = registry()
        let kinds = registry.descriptors.compactMap { registry.make(id: $0.id).map { ($0.id, $0.connectionKind) } }
        #expect(kinds.map(\.0) == ["dexcom-share", "dexcom-g6", "dexcom-g7"])
        #expect(kinds.map(\.1) == [.cloudPoll, .localBLE, .localBLE])
    }

    @Test("Bluetooth restore identifiers are fixed, distinct, and never the pump's")
    func restoreIdentifiers() {
        let ids = [GlucoseSourceRegistry.g6RestoreIdentifier, GlucoseSourceRegistry.g7RestoreIdentifier]
        #expect(Set(ids).count == 2)
        #expect(!ids.contains("com.fabolus.app.pump"))
        #expect(ids == ["com.fabolus.app.cgm.dexcom-g6", "com.fabolus.app.cgm.dexcom-g7"])
    }

    @Test("selecting a source persists it; nil is the pump's glucose only")
    func selection() {
        let registry = registry()
        #expect(registry.selectedID == nil)
        #expect(registry.makeSelected() == nil)
        registry.select("dexcom-g7")
        #expect(registry.selected?.name == "Dexcom G7 (direct Bluetooth)")
        #expect(registry.makeSelected()?.id == "dexcom-g7")
        registry.select("gone")
        #expect(registry.makeSelected() == nil)
        registry.select(nil)
        #expect(registry.selectedID == nil)
    }

    @Test("selecting a source again clears the crash-loop hold of the one before")
    func selectClearsRecovery() {
        let registry = registry()
        registry.select("dexcom-g6")
        var now = t0
        for _ in 0..<GlucoseSourceRecoveryPolicy.maxUncleanStartsBeforeDisable {
            _ = registry.shouldStartSelected(now: now)
            now.addTimeInterval(60)
        }
        #expect(registry.disabledUntil != nil)
        #expect(!registry.shouldStartSelected(now: now))
        registry.select("dexcom-g6")
        #expect(registry.disabledUntil == nil)
        #expect(registry.shouldStartSelected(now: now))
    }

    @Test("a clean shutdown keeps the next launch counted as clean")
    func cleanShutdown() {
        let registry = registry()
        registry.select("dexcom-share")
        for minute in 0..<5 {
            #expect(registry.shouldStartSelected(now: t0.addingTimeInterval(Double(minute) * 60)))
            registry.markCleanShutdown()
        }
    }

    @Test("the G6 transmitter ID typed in settings is checked, normalized and clearable")
    func transmitterIDEntry() throws {
        let registry = registry()
        #expect(try registry.setG6TransmitterID(" 8g12ab ") == "8G12AB")
        #expect(registry.settings.g6TransmitterID == "8G12AB")
        #expect(throws: GlucoseSourceRegistry.TransmitterIDError.invalid) { try registry.setG6TransmitterID("8G12") }
        #expect(registry.settings.g6TransmitterID == "8G12AB")
        #expect(try registry.setG6TransmitterID("") == nil)
        #expect(registry.settings.g6TransmitterID == nil)
    }

    @Test("Share credentials saved through the registry reach the Share source")
    func shareThroughRegistry() async throws {
        let registry = registry()
        try registry.account.save(username: "u", password: "p", region: .us)
        #expect(registry.account.credentials?.username == "u")
        registry.select("dexcom-share")
        #expect(registry.makeSelected()?.connectionKind == .cloudPoll)
    }

    @Test("removing all settings forgets the selection, IDs and remembered peripherals")
    func removeAll() throws {
        let registry = registry()
        registry.select("dexcom-g6")
        try registry.setG6TransmitterID("8G12AB")
        registry.settings.removeAll()
        #expect(registry.selectedID == nil)
        #expect(registry.settings.g6TransmitterID == nil)
    }
}

@Suite("Restore identifier claims")
struct RestoreIdentifierClaimTests {
    @Test("a second central with the same restore identifier runs without restoration instead of crashing")
    func secondClaimRefused() {
        let id = "com.fabolus.app.cgm.test-\(UUID().uuidString)"
        let first = DexcomCentral(restoreIdentifier: id, emit: { _ in })
        let second = DexcomCentral(restoreIdentifier: id, emit: { _ in })
        #expect(first.usesRestoreIdentifier)
        #expect(!second.usesRestoreIdentifier)
        _ = (first, second)
    }
}
