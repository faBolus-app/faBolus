import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that the CGM registry on main is Dexcom Share only, and that HealthKit, Nightscout, and other
/// removed sources have no descriptor. A reintroduced source would sit on the arbiter merge path.
@MainActor
private final class MockShareLikeGlucoseSource: GlucoseSource {
    let id: String
    let priority = 90
    let connectionKind: GlucoseConnectionKind = .cloudPoll  // Share-shaped: a cloud-polled source
    var latest: GlucoseSample?
    var history: [GlucoseReading]
    var status: GlucoseSourceStatus = .connected
    var onChange: (@MainActor () -> Void)?
    init(id: String = "dexcom-share", latest: GlucoseSample?, history: [GlucoseReading] = []) {
        self.id = id
        self.latest = latest
        self.history = history
    }
    func start() async {}
    func stop() {}
}

@MainActor
struct CgmShareOnlyBoundaryTests {

    /// `GlucoseSourceRegistry.enabled` contains only Dexcom Share — HealthKit and Nightscout are gone from main.
    @Test func registryContainsOnlyDexcomShare() {
        let expected: Set<String> = ["dexcom-share"]
        let actual = Set(GlucoseSourceRegistry.enabled.map(\.id))
        #expect(
            actual == expected,
            "narrow main's CGM registry must be exactly \(expected); got \(actual)")
    }

    /// Every source this milestone removes is fully gone from the registry: absent from `enabled` AND
    /// `descriptor(id:)` returns nil (not merely hidden from the default UI).
    @Test func removedSourceIdsAreAbsent() {
        let enabledIds = Set(GlucoseSourceRegistry.enabled.map(\.id))
        for id in ["dexcom-g7-ble", "dexcom-g6-ble", "librelinkup", "xdrip-appgroup", "nightscout", "healthkit"] {
            #expect(!enabledIds.contains(id), "\(id) must be removed from GlucoseSourceRegistry.enabled")
            #expect(
                GlucoseSourceRegistry.descriptor(id: id) == nil,
                "\(id) must have no descriptor at all, not just be unlisted")
        }
    }

    /// `GlucoseArbiter.merge` is source-agnostic: a fresh Share-shaped sample must still beat a stale pump snapshot.
    @Test func shareReadingFlowsThroughArbiterMerge() throws {
        var stalePump = PumpSnapshot()
        stalePump.glucose = 100
        stalePump.glucoseDate = Date().addingTimeInterval(-10 * 60)  // 10 min old → stale (>6 min)
        stalePump.trend = GlucoseTrend.flat.rawValue

        let freshShareSample = try #require(
            GlucoseSample(mgdl: 145, date: Date().addingTimeInterval(-30), trend: .up, sourceID: "dexcom-share"))
        let shareSource = MockShareLikeGlucoseSource(id: "dexcom-share", latest: freshShareSample)

        let (merged, _, provenance) = GlucoseArbiter.merge(
            pumpSnapshot: stalePump, pumpHistory: [], source: shareSource)

        #expect(merged.glucose == 145, "the fresher Share reading must win over the stale pump value")
        #expect(merged.trend == GlucoseTrend.up.rawValue)
        #expect(merged.cgmActive)
        #expect(provenance == .failover(sourceID: "dexcom-share", reason: .pumpStale))
    }
}
