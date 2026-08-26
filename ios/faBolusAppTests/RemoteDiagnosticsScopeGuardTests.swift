import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.6-07 (Task 2, D-03.1, D-04, T-09.6-06): makes the "the new `.diagnosticsRead` wire member
/// is provably delivery-inert" rule self-enforcing, modeled on `WatchDirectBleScopeGuardTests`'
/// `#filePath`-rooted source scan technique.
///
/// (a) Type-level: `.diagnosticsRead` is non-mutating + non-freshness-sensitive, and the FULL
/// exhaustive mutating-kind set (via `RemoteCommand.Kind.allCases`, added in this plan) equals a
/// pinned baseline that does NOT contain `.diagnosticsRead` — any future widening of the
/// `mutatesPumpState` true-branch turns this guard RED.
///
/// Phase 17.5 (D1-01): parts (b) and (c) — which source-scanned the now-deleted WatchConnectivity
/// transport host and the now-removed watch-diagnostics-request call site — are retired along with
/// that machinery. `.diagnosticsRead`'s own type-level inertness (part a) is untouched here; the enum
/// case itself and `WatchSelfDiagnostics` remain Plan 03's scope to retire.
struct RemoteDiagnosticsScopeGuardTests {

    // MARK: - (a) Type-level inertness

    /// Pinned from `RemoteCommand.Kind`'s `mutatesPumpState` true branch as it stood going INTO this
    /// plan (unchanged by it) — `.diagnosticsRead` is added to the FALSE branch, so this set is
    /// untouched. Any future case moved into the true branch, or added there, turns this RED.
    private static let pinnedMutatingBaseline: Set<RemoteCommand.Kind> = [
        .bolusRequest, .bolusConfirm, .cancelBolus, .suspendPump, .resumePump,
        .dismissAlert, .bolusApprovalRequest, .bolusApprovalResponse, .sealed,
    ]

    @Test func diagnosticsReadIsInertAndExhaustiveMutatingSetMatchesPinnedBaseline() {
        #expect(RemoteCommand.Kind.diagnosticsRead.mutatesPumpState == false)
        #expect(RemoteCommand.Kind.diagnosticsRead.isFreshnessSensitive == false)

        let actualMutating = Set(RemoteCommand.Kind.allCases.filter { $0.mutatesPumpState })
        #expect(actualMutating == Self.pinnedMutatingBaseline,
                "the exhaustive mutating-kind set drifted from the pinned baseline")
        #expect(!actualMutating.contains(.diagnosticsRead),
                ".diagnosticsRead must never be classified as pump-mutating")
    }
}
