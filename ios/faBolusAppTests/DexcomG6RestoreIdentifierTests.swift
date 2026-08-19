import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// D-06: proves the fix for the duplicate-restore-identifier CoreBluetooth SIGABRT —
/// `CBCentralManagerOptionRestoreIdentifierKey` is scoped to the ONE long-lived production
/// `DexcomG6BLESource` instance (`GlucoseSourceRegistry.makeSelected()`); the ephemeral
/// `CgmCredentialsView` "Test" instance (`GlucoseSourceRegistry.make(id:)`) always gets none. All
/// assertions here are construction-time / source-scan — no live `CBCentralManager`, no BLE, no
/// simulator restoration (CoreBluetooth state restoration cannot be driven from XCTest/Swift
/// Testing).
@MainActor
struct DexcomG6RestoreIdentifierTests {

    // MARK: Task 1 — construction-time restore-identifier scoping

    /// The production path (`makeSelected()`, `restoreStateEnabled: true`) carries the stable
    /// restore identifier.
    @Test func productionInstanceCarriesStableRestoreIdentifier() throws {
        let descriptor = try #require(GlucoseSourceRegistry.descriptor(id: "dexcom-g6-ble"))
        let production = try #require(descriptor.make(true) as? DexcomG6BLESource)
        #expect(production.restoreIdentifierForTesting == "com.fabolus.cgm.dexcom-g6-ble")
    }

    /// The ephemeral "Test" path (`make(id:)`, `restoreStateEnabled: false`) carries none — this is
    /// the half of the fix that prevents the SIGABRT: it can never collide with the production
    /// instance's restore-identifier string.
    @Test func testInstanceCarriesNoRestoreIdentifier() throws {
        let descriptor = try #require(GlucoseSourceRegistry.descriptor(id: "dexcom-g6-ble"))
        let testInstance = try #require(descriptor.make(false) as? DexcomG6BLESource)
        #expect(testInstance.restoreIdentifierForTesting == nil)
    }

    /// `GlucoseSourceRegistry.makeSelected()` / `.make(id:)` route to the right flag (not just the
    /// descriptor's own `make(_:)` — the actual call sites the app uses).
    @Test func registryCallSitesRouteToTheCorrectFlag() throws {
        GlucoseSourceRegistry.select("dexcom-g6-ble")
        defer { GlucoseSourceRegistry.select(nil) }

        let production = try #require(GlucoseSourceRegistry.makeSelected() as? DexcomG6BLESource)
        #expect(production.restoreIdentifierForTesting == "com.fabolus.cgm.dexcom-g6-ble")

        let testInstance = try #require(GlucoseSourceRegistry.make(id: "dexcom-g6-ble") as? DexcomG6BLESource)
        #expect(testInstance.restoreIdentifierForTesting == nil)
    }

    /// Textually stable across relaunches: building the production instance twice (two separate
    /// process "launches" in spirit) yields the identical string — never derived from a
    /// timestamp/UUID, which CoreBluetooth state restoration requires to keep working.
    @Test func restoreIdentifierIsTextuallyStableAcrossConstructions() throws {
        let descriptor = try #require(GlucoseSourceRegistry.descriptor(id: "dexcom-g6-ble"))
        let first = try #require(descriptor.make(true) as? DexcomG6BLESource)
        let second = try #require(descriptor.make(true) as? DexcomG6BLESource)
        #expect(first.restoreIdentifierForTesting == second.restoreIdentifierForTesting)
        #expect(first.restoreIdentifierForTesting == DexcomG6BLESource.productionRestoreIdentifier)
    }

    /// Every OTHER descriptor closure ignores the flag (mechanical `_ in` edit, per the plan — no
    /// `DexcomG7BLESource` source change, D-11) and still builds successfully with either value.
    /// "healthkit" only has a descriptor when `FABOLUS_HEALTHKIT` is ON (D-13, Phase 09.23) — gated
    /// here too, an unavoidable direct consequence of that gating (not itself part of the 09.23-01
    /// plan's declared scope).
    @Test func everyOtherDescriptorClosureIgnoresTheFlag() throws {
        var ids = ["dexcom-g7-ble", "librelinkup", "nightscout", "dexcom-share", "xdrip-appgroup"]
        #if FABOLUS_HEALTHKIT
        ids.append("healthkit")
        #endif
        for id in ids {
            let descriptor = try #require(GlucoseSourceRegistry.descriptor(id: id), "missing descriptor: \(id)")
            #expect(descriptor.make(true).id == id)
            #expect(descriptor.make(false).id == id)
        }
    }

    // MARK: Task 2 — willRestoreState reattachment (source-scan; CB restoration isn't simulatable)

    /// Resolve `<root>` by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/DexcomG6RestoreIdentifierTests.swift`) until `Shared` exists —
    /// same technique as `DexcomG6ScopeGuardTests.repoRootURL()` / `WatchDirectBleScopeGuardTests`.
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

    private static let sourcePath = "ios/faBolus/Data/Sources/DexcomG6BLESource.swift"

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

    /// `DexcomG6BLESource` implements `centralManager(_:willRestoreState:)` and reattaches from
    /// `CBCentralManagerRestoredStatePeripheralsKey` (delegate + connect), mirroring
    /// `faBolusCore/BLELink.swift`'s central-role `willRestoreState`.
    @Test func implementsWillRestoreStateReattachment() throws {
        let code = try #require(Self.readSource())
        #expect(code.contains("willRestoreState"),
                "expected a willRestoreState delegate method for background reattachment (D-06)")
        #expect(code.contains("CBCentralManagerRestoredStatePeripheralsKey"),
                "willRestoreState must read CBCentralManagerRestoredStatePeripheralsKey to recover the restored peripheral")
        #expect(code.contains(".delegate = self"),
                "the restored peripheral must be reattached as this source's delegate")
        #expect(code.contains("central.connect("),
                "the restored peripheral must be (re)connected if CoreBluetooth hasn't already done so")
    }

    /// The existing cold-join path (`retrieveConnectedPeripherals` in
    /// `centralManagerDidUpdateState`) must still be present — background relaunch re-adopts the
    /// already-connected peripheral via EITHER path, and this one was already proven correct for
    /// joining the Dexcom app's live session (Plan 01/02).
    @Test func coldJoinPathIsPreserved() throws {
        let code = try #require(Self.readSource())
        #expect(code.contains("retrieveConnectedPeripherals"),
                "the cold-join path must remain — do not remove it when adding willRestoreState")
    }

    /// Never a characteristic write, even in the new restoration path — the Plan 01 scope-guard
    /// property (D-12a) must hold for every line added in this plan too.
    @Test func willRestoreStateNeverWritesACharacteristic() throws {
        let code = try #require(Self.readSource())
        #expect(!code.contains("writeValue("),
                "must never call CBPeripheral.writeValue(for:type:) — passive-read-only source (D-12a)")
    }

    // MARK: H-01 (09.20-REVIEW.md) — the already-connected restore branch must force its own
    // fresh discovery/subscribe cycle, not depend on `centralManagerDidUpdateState`'s separate
    // cold-join side effect. Source-scan, scoped narrowly to the `willRestoreState` function body
    // (not the whole file — `discoverServices(` already appears elsewhere, e.g. `didConnect`, so an
    // unscoped `code.contains` would vacuously pass even before the fix).

    /// Isolate the `willRestoreState` delegate method's body text, bounded by the next delegate
    /// method declared immediately after it in this file (`centralManagerDidUpdateState`), so the
    /// assertions below can't be satisfied by code living in a DIFFERENT delegate method.
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

    @Test func alreadyConnectedRestoreBranchForcesFreshDiscovery() throws {
        let body = try Self.willRestoreStateBody()
        #expect(!body.isEmpty, "willRestoreState function body could not be isolated — scan boundaries likely broke")
        #expect(body.contains("restored.state == .connected"),
                "the already-connected case must be explicitly branched on (H-01)")
        #expect(body.contains("discoverServices("),
                "the already-connected restore branch must force fresh service/characteristic discovery itself, rather than depending on an undocumented centralManagerDidUpdateState side effect (H-01)")
    }

    /// The already-connected branch's forced rediscovery must still never write a characteristic —
    /// re-affirms D-12a specifically within the narrower H-01 scan boundary (not just file-wide, as
    /// `willRestoreStateNeverWritesACharacteristic` above already checks).
    @Test func alreadyConnectedRestoreBranchNeverWritesACharacteristic() throws {
        let body = try Self.willRestoreStateBody()
        #expect(!body.isEmpty, "willRestoreState function body could not be isolated — scan boundaries likely broke")
        #expect(!body.contains("writeValue("),
                "must never call CBPeripheral.writeValue(for:type:) — passive-read-only source (D-12a)")
    }
}
