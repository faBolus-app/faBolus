import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Originally Phase 1 (CGM → Dexcom Share only), Plan 01 (D-06): the app-target boundary test that
/// pins the narrow-`main` CGM-source contract. `registryContainsOnlyDexcomShare` and
/// `removedSourceIdsAreAbsent` converged to fully GREEN once Phase 1's Plans 02/03 landed, and were
/// extended here in Phase 5 (`registryContainsOnlyDexcomShare`, renamed from
/// `registryContainsOnlyShareAndNightscout`) to also cover HealthKit's (HEALTH-01) and Nightscout's
/// (HEALTH-02) removal. Mirrors `CgmSourceValidationTests`' registry-enumeration style
/// (construction-time, no live source, no simulator).
///
/// A stand-in `GlucoseSource` for the arbiter-contract test (Task 2, D-05) — mirrors
/// `GlucoseArbiterTests.MockGlucoseSource` in `Packages/faBolusCore`, reproduced here (not imported —
/// that type is `private` to its own test target) so this app-target test consumes ONLY the public
/// `faBolusCore` API, never a removed/renamed concrete source type.
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

    /// The end state of Phase 5 (HEALTH-01/HEALTH-02): `GlucoseSourceRegistry.enabled` contains ONLY
    /// Dexcom Share — HealthKit and Nightscout are both gone from narrow `main` (see dev/healthkit's
    /// and dev/nightscout's REINTEGRATION.md).
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

    /// D-05/D-06: `GlucoseArbiter.merge` is source-agnostic and stays byte-identical across every
    /// removal in this phase — a fresh Share-shaped `GlucoseSample` must still beat a stale
    /// `PumpSnapshot` exactly as it does for every other source. Mirrors
    /// `GlucoseArbiterTests.testFailsOverWhenPumpStale`: a 10-min-stale pump snapshot vs. a
    /// 30-second-fresh Share-shaped sample, through the real `GlucoseArbiter.merge`. Uses ONLY the
    /// public `Packages/faBolusCore` API (`GlucoseArbiter`, `PumpSnapshot`, `GlucoseSample`,
    /// `GlucoseProvenance`, `GlucoseSource`) — never names a removed concrete source type.
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
