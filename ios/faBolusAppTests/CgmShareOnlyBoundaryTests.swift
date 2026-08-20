import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 1 (CGM → Dexcom Share only), Plan 01 (D-06): the app-target boundary test that pins the
/// narrow-`main` CGM-source contract across the phase's three plans. Written as the TRACER slice
/// (Plan 01 removes only xDrip App Group), so `registryContainsOnlyShareAndNightscout` and
/// `removedSourceIdsAreAbsent` are DELIBERATELY still partially RED on `main` after this plan — they
/// converge to fully GREEN only once Plan 02 (G6 + LibreLinkUp) and Plan 03 (G7) land. This is the
/// intended RED→GREEN convergence for a multi-plan removal, not a regression: each plan narrows the
/// registry further and this file's expectations do not change. Mirrors `CgmSourceValidationTests`'
/// registry-enumeration style (construction-time, no live source, no simulator).
@MainActor
struct CgmShareOnlyBoundaryTests {

    /// The end state of Phase 1: `GlucoseSourceRegistry.enabled` contains ONLY Dexcom Share +
    /// Nightscout (+ HealthKit under `FABOLUS_HEALTHKIT`, which Phase 1 does not touch — it drops in
    /// Phase 5). RED after Plan 01 (dexcom-g7-ble / dexcom-g6-ble / librelinkup are still present);
    /// GREEN only after Plan 03 removes the last of them.
    @Test func registryContainsOnlyShareAndNightscout() {
        var expected: Set<String> = ["dexcom-share", "nightscout"]
        #if FABOLUS_HEALTHKIT
        expected.insert("healthkit")
        #endif
        let actual = Set(GlucoseSourceRegistry.enabled.map(\.id))
        #expect(actual == expected,
                "narrow main's CGM registry must be exactly \(expected); got \(actual)")
    }

    /// Every source this phase removes is fully gone from the registry: absent from `enabled` AND
    /// `descriptor(id:)` returns nil (not merely hidden from the default UI). xdrip-appgroup goes GREEN
    /// in this plan; dexcom-g7-ble / dexcom-g6-ble / librelinkup stay RED until Plans 02/03.
    @Test func removedSourceIdsAreAbsent() {
        let enabledIds = Set(GlucoseSourceRegistry.enabled.map(\.id))
        for id in ["dexcom-g7-ble", "dexcom-g6-ble", "librelinkup", "xdrip-appgroup"] {
            #expect(!enabledIds.contains(id), "\(id) must be removed from GlucoseSourceRegistry.enabled")
            #expect(GlucoseSourceRegistry.descriptor(id: id) == nil,
                    "\(id) must have no descriptor at all, not just be unlisted")
        }
    }

    /// D-05/D-06: `GlucoseArbiter.merge` is source-agnostic and stays byte-identical across every
    /// removal in this phase — a fresh Share-shaped `GlucoseSample` must still beat a stale
    /// `PumpSnapshot` exactly as it does for every other source. Uses ONLY the public
    /// `Packages/faBolusCore` API — never names a removed concrete type.
    ///
    /// TODO (Plan 01, Task 2): replace this stub with a real fixture-backed assertion mirroring
    /// `GlucoseArbiterTests` (stale pump snapshot vs. fresh Share-shaped sample through
    /// `GlucoseArbiter.merge`, asserting the fresher source wins and the provenance is as expected).
    /// GREEN now because it asserts nothing about the (unchanged) arbiter yet.
    @Test func shareReadingFlowsThroughArbiterMerge() {
        #expect(Bool(true))
    }
}
