import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Behavior-preserving equivalence proof for the pure mappers relocated from `AppModel` into
/// `FailoverBadgePresenter`:
/// `failoverBadge`/`shortSourceName` (the failover badge shown to the user) and
/// `shouldPushStatus` (the already-pure status-push predicate). Every expected value pinned here
/// is the value the ORIGINAL `AppModel` body returned before the move — a hardcoded "was this
/// identical before/after" fixture, not a re-derivation from the new code.
@MainActor
struct FailoverBadgePresenterTests {

    // MARK: - failoverBadge (registered source id)

    @Test func pumpProvenanceHasNoBadge() {
        #expect(FailoverBadgePresenter.failoverBadge(provenance: .pump) == nil)
    }

    @Test func registeredSourcePumpMissingRendersFullNameAndReason() {
        let badge = FailoverBadgePresenter.failoverBadge(
            provenance: .failover(sourceID: "dexcom-share", reason: .pumpMissing))
        #expect(badge?.name == "Dexcom Share")
        #expect(badge?.reason == "Showing Dexcom Share (cloud) — the pump has no CGM reading.")
    }

    @Test func registeredSourcePumpStaleRendersFullNameAndReason() {
        let badge = FailoverBadgePresenter.failoverBadge(
            provenance: .failover(sourceID: "dexcom-share", reason: .pumpStale))
        #expect(badge?.name == "Dexcom Share")
        #expect(badge?.reason == "Showing Dexcom Share (cloud) — the pump's CGM reading went stale.")
    }

    /// An unregistered source id (no `GlucoseSourceDescriptor` in `GlucoseSourceRegistry.enabled`)
    /// falls back to the raw id itself, exactly as the pre-move body did (`?? sourceID`).
    @Test func unregisteredSourceFallsBackToRawId() {
        let badge = FailoverBadgePresenter.failoverBadge(
            provenance: .failover(sourceID: "dexcom-g7", reason: .pumpStale))
        #expect(badge?.name == "dexcom-g7")
        #expect(badge?.reason == "Showing dexcom-g7 — the pump's CGM reading went stale.")
    }

    // MARK: - shortSourceName

    @Test func shortSourceNameDropsParentheticalQualifier() {
        #expect(FailoverBadgePresenter.shortSourceName("Dexcom Share (cloud)") == "Dexcom Share")
    }

    @Test func shortSourceNameDropsSlashQualifier() {
        #expect(FailoverBadgePresenter.shortSourceName("Dexcom G7 / ONE+ (direct BLE)") == "Dexcom G7")
    }

    @Test func shortSourceNameDropsEmDashQualifier() {
        #expect(FailoverBadgePresenter.shortSourceName("Nightscout — self-hosted") == "Nightscout")
    }

    @Test func shortSourceNameWithNoQualifierPassesThrough() {
        #expect(FailoverBadgePresenter.shortSourceName("LibreLinkUp") == "LibreLinkUp")
    }

    // MARK: - shouldPushStatus (table-driven — pre/post-move identical booleans; the exhaustive
    // fixture also lives in StatusPushCadenceTests.swift, which now calls the SAME relocated
    // function — kept here too as the equivalence table for this mapper.)

    private static let t0 = Date(timeIntervalSince1970: 2_000_000)

    @Test func newSampleAtSameValuePushes() {
        #expect(
            FailoverBadgePresenter.shouldPushStatus(
                newGlucose: 100, newGlucoseDate: Self.t0.addingTimeInterval(300),
                lastGlucose: 100, lastGlucoseDate: Self.t0,
                newConnection: .connected, lastConnection: .connected,
                secondsSinceLastPush: 1))
    }

    @Test func identicalSampleWithinThrottleDoesNotPush() {
        #expect(
            !FailoverBadgePresenter.shouldPushStatus(
                newGlucose: 100, newGlucoseDate: Self.t0,
                lastGlucose: 100, lastGlucoseDate: Self.t0,
                newConnection: .connected, lastConnection: .connected,
                secondsSinceLastPush: 1))
    }

    @Test func throttleWindowElapsedForcesAPush() {
        #expect(
            FailoverBadgePresenter.shouldPushStatus(
                newGlucose: 100, newGlucoseDate: Self.t0,
                lastGlucose: 100, lastGlucoseDate: Self.t0,
                newConnection: .connected, lastConnection: .connected,
                secondsSinceLastPush: 16))
    }

    @Test func connectionChangeAlwaysPushes() {
        #expect(
            FailoverBadgePresenter.shouldPushStatus(
                newGlucose: 100, newGlucoseDate: Self.t0, lastGlucose: 100, lastGlucoseDate: Self.t0,
                newConnection: .disconnected, lastConnection: .connected, secondsSinceLastPush: 1))
    }

    @Test func bolusingAlwaysPushes() {
        #expect(
            FailoverBadgePresenter.shouldPushStatus(
                newGlucose: 100, newGlucoseDate: Self.t0, lastGlucose: 100, lastGlucoseDate: Self.t0,
                newConnection: .bolusing, lastConnection: .bolusing, secondsSinceLastPush: 1))
    }

    @Test func customThrottleIsRespected() {
        #expect(
            !FailoverBadgePresenter.shouldPushStatus(
                newGlucose: 100, newGlucoseDate: Self.t0, lastGlucose: 100, lastGlucoseDate: Self.t0,
                newConnection: .connected, lastConnection: .connected,
                secondsSinceLastPush: 25, throttle: 30))
        #expect(
            FailoverBadgePresenter.shouldPushStatus(
                newGlucose: 100, newGlucoseDate: Self.t0, lastGlucose: 100, lastGlucoseDate: Self.t0,
                newConnection: .connected, lastConnection: .connected,
                secondsSinceLastPush: 31, throttle: 30))
    }
}
