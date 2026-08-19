import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// D-08: proves G7 gets the same background-failover parity G6 has — a DISTINCT stable restore
/// identifier scoped to the ONE long-lived production `DexcomG7BLESource` instance
/// (`GlucoseSourceRegistry.makeSelected()`); the ephemeral `CgmCredentialsView` "Test" instance
/// (`GlucoseSourceRegistry.make(id:)`) always gets none, so two `CBCentralManager`s never share a
/// restore-identifier string (the CoreBluetooth SIGABRT). All assertions are construction-time /
/// source-scan — no live `CBCentralManager`, no BLE, no simulator restoration (CoreBluetooth state
/// restoration cannot be driven from XCTest/Swift Testing). Mirrors `DexcomG6RestoreIdentifierTests`.
@MainActor
struct DexcomG7RestoreIdentifierTests {

    // MARK: Construction-time restore-identifier scoping

    /// The production path (`makeSelected()`, `restoreStateEnabled: true`) carries the stable restore
    /// identifier `com.fabolus.cgm.dexcom-g7-ble`.
    @Test func productionInstanceCarriesStableRestoreIdentifier() throws {
        let descriptor = try #require(GlucoseSourceRegistry.descriptor(id: "dexcom-g7-ble"))
        let production = try #require(descriptor.make(true) as? DexcomG7BLESource)
        #expect(production.restoreIdentifierForTesting == "com.fabolus.cgm.dexcom-g7-ble")
    }

    /// The ephemeral "Test" path (`make(id:)`, `restoreStateEnabled: false`) carries none — the half
    /// of the fix that prevents the SIGABRT: it can never collide with the production instance's
    /// restore-identifier string.
    @Test func testInstanceCarriesNoRestoreIdentifier() throws {
        let descriptor = try #require(GlucoseSourceRegistry.descriptor(id: "dexcom-g7-ble"))
        let testInstance = try #require(descriptor.make(false) as? DexcomG7BLESource)
        #expect(testInstance.restoreIdentifierForTesting == nil)
    }

    /// `GlucoseSourceRegistry.makeSelected()` / `.make(id:)` route to the right flag (not just the
    /// descriptor's own `make(_:)` — the actual call sites the app uses).
    @Test func registryCallSitesRouteToTheCorrectFlag() throws {
        GlucoseSourceRegistry.select("dexcom-g7-ble")
        defer { GlucoseSourceRegistry.select(nil) }

        let production = try #require(GlucoseSourceRegistry.makeSelected() as? DexcomG7BLESource)
        #expect(production.restoreIdentifierForTesting == "com.fabolus.cgm.dexcom-g7-ble")

        let testInstance = try #require(GlucoseSourceRegistry.make(id: "dexcom-g7-ble") as? DexcomG7BLESource)
        #expect(testInstance.restoreIdentifierForTesting == nil)
    }

    /// Textually stable across relaunches: building the production instance twice yields the identical
    /// string — never derived from a timestamp/UUID, which CoreBluetooth state restoration requires.
    @Test func restoreIdentifierIsTextuallyStableAcrossConstructions() throws {
        let descriptor = try #require(GlucoseSourceRegistry.descriptor(id: "dexcom-g7-ble"))
        let first = try #require(descriptor.make(true) as? DexcomG7BLESource)
        let second = try #require(descriptor.make(true) as? DexcomG7BLESource)
        #expect(first.restoreIdentifierForTesting == second.restoreIdentifierForTesting)
        #expect(first.restoreIdentifierForTesting == DexcomG7BLESource.productionRestoreIdentifier)
    }

    /// No collision: the G7 restore id differs from the pump, watch, BLELink, and G6 identifiers — the
    /// four other stable restore-id strings in the process (D-08).
    @Test func restoreIdentifierDoesNotCollideWithAnyOtherRestoreId() {
        let g7 = DexcomG7BLESource.productionRestoreIdentifier
        #expect(g7 == "com.fabolus.cgm.dexcom-g7-ble")
        #expect(g7 != "com.fabolus.app.pump", "must not collide with the pump restore id")
        #expect(g7 != "com.fabolus.app.watch.pump", "must not collide with the watch pump restore id")
        #expect(g7 != "com.fabolus.ble.central", "must not collide with the BLELink restore id")
        #expect(g7 != DexcomG6BLESource.productionRestoreIdentifier, "must not collide with the G6 restore id")
        #expect(g7 != "com.fabolus.cgm.dexcom-g6-ble")
    }

    // MARK: willRestoreState reattachment (source-scan; CB restoration isn't simulatable)

    /// Resolve `<root>` by walking up from `#filePath` until `Shared` exists — same technique as
    /// `DexcomG6ScopeGuardTests.repoRootURL()`.
    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("Shared")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static let sourcePath = "Shared/DexcomG7BLESource.swift"

    private static func readSource() -> String? {
        guard let root = repoRootURL() else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(Self.sourcePath), encoding: .utf8)
    }

    /// Vacuous-pass guard: fail loudly if the source file can't be resolved, rather than silently
    /// passing every scan below because `readSource` returned nil.
    @Test func sourceFileResolvesFromFilePath() throws {
        #expect(Self.readSource() != nil,
                "path resolution broke: could not read \(Self.sourcePath) from #filePath=\(#filePath)")
    }

    /// `DexcomG7BLESource` implements `centralManager(_:willRestoreState:)` and reattaches from
    /// `CBCentralManagerRestoredStatePeripheralsKey` (delegate + connect), mirroring `DexcomG6BLESource`.
    @Test func implementsWillRestoreStateReattachment() throws {
        let code = try #require(Self.readSource())
        #expect(code.contains("willRestoreState"),
                "expected a willRestoreState delegate method for background reattachment (D-08)")
        #expect(code.contains("CBCentralManagerRestoredStatePeripheralsKey"),
                "willRestoreState must read CBCentralManagerRestoredStatePeripheralsKey to recover the restored peripheral")
        #expect(code.contains(".delegate = self"),
                "the restored peripheral must be reattached as this source's delegate")
        #expect(code.contains("central.connect("),
                "the restored peripheral must be (re)connected if CoreBluetooth hasn't already done so")
    }

    /// The existing cold-join path (`retrieveConnectedPeripherals` in `centralManagerDidUpdateState`)
    /// must still be present — background relaunch re-adopts the already-connected peripheral via
    /// EITHER path, and this one was already proven correct for joining the Dexcom app's live session.
    @Test func coldJoinPathIsPreserved() throws {
        let code = try #require(Self.readSource())
        #expect(code.contains("retrieveConnectedPeripherals"),
                "the cold-join path must remain — do not remove it when adding willRestoreState")
    }

    /// Never a characteristic write, even in the new restoration path — the scope-guard property
    /// (D-12a) must hold for every line added in this plan too.
    @Test func willRestoreStateNeverWritesACharacteristic() throws {
        let code = try #require(Self.readSource())
        #expect(!code.contains("writeValue("),
                "must never call CBPeripheral.writeValue(for:type:) — passive-read-only source (D-12a)")
    }

    // MARK: willRestoreState body — the already-connected branch must force its own fresh discovery
    // using G7's cgmService, not depend on `centralManagerDidUpdateState`'s cold-join side effect.

    /// Isolate the `willRestoreState` method body, bounded by the next delegate method declared after
    /// it (`centralManagerDidUpdateState`), so assertions can't be satisfied by code in a DIFFERENT
    /// delegate method (`discoverServices(` already appears elsewhere, e.g. `didConnect`).
    private static func willRestoreStateBody() throws -> String {
        let code = try #require(Self.readSource())
        let startMarker = "willRestoreState dict: [String: Any]) {"
        guard let startRange = code.range(of: startMarker) else {
            Issue.record("could not locate the willRestoreState function signature")
            return ""
        }
        guard let endRange = code.range(of: "func centralManagerDidUpdateState",
                                        range: startRange.upperBound..<code.endIndex) else {
            Issue.record("could not locate the end boundary (centralManagerDidUpdateState) after willRestoreState")
            return ""
        }
        return String(code[startRange.upperBound..<endRange.lowerBound])
    }

    @Test func alreadyConnectedRestoreBranchForcesFreshDiscoveryWithG7Service() throws {
        let body = try Self.willRestoreStateBody()
        #expect(!body.isEmpty, "willRestoreState function body could not be isolated — scan boundaries likely broke")
        #expect(body.contains("restored.state == .connected"),
                "the already-connected case must be explicitly branched on (mirror G6's H-01)")
        #expect(body.contains("discoverServices("),
                "the already-connected restore branch must force fresh service/characteristic discovery itself")
        #expect(body.contains("SensorServiceUUID.cgmService"),
                "the forced rediscovery must use G7's SensorServiceUUID.cgmService, not G6's TransmitterServiceUUID")
    }

    @Test func willRestoreStateBodyNeverWritesACharacteristic() throws {
        let body = try Self.willRestoreStateBody()
        #expect(!body.isEmpty, "willRestoreState function body could not be isolated — scan boundaries likely broke")
        #expect(!body.contains("writeValue("),
                "must never call CBPeripheral.writeValue(for:type:) — passive-read-only source (D-12a)")
    }
}
