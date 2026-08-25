import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// CC-10 (Phase 15 15-04, review-sharpened HIGH "AAM storage behavior is unspecified"): the active-alert-
/// malfunction (AAM) read fan-in. `alertRead()`'s periodic burst never asked for `HighestAamRequest`/
/// `ActiveAamBitsRequest` — both already exist in the pinned TandemKit commit and are registered in
/// `ResponseParser` — so the app could never surface an active malfunction fan-in. This suite pins two
/// facts: (1) the two AAM requests are composed into the SAME burst, in dispatch order, after the existing
/// 5; (2) applying their responses populates TandemBackend's NAMED, replace-on-read AAM state
/// (`highestAam`/`activeAamBits`) — never `mergeNotifications`/`activeNotifications`/`snapshot` (display +
/// malfunction cross-validation is Phase 13, out of scope here).
@Suite(.serialized) @MainActor
struct PumpReadSchedulerAamFanInTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    /// The FULL 7-request `alertRead()` burst, in dispatch order (kept as a local literal, mirroring
    /// `ReadCascadeMembershipGuardTests.alertReadTier`, so this suite doesn't reach across test-file
    /// boundaries for a shared static).
    private static let alertReadTier = [
        "AlertStatusRequest", "AlarmStatusRequest", "CGMAlertStatusRequest", "ReminderStatusRequest",
        "MalfunctionStatusRequest", "HighestAamRequest", "ActiveAamBitsRequest",
    ]

    // MARK: - Composition: the 2 AAM requests join the SAME burst, in order, after the original 5

    @Test func alertReadComposesTheTwoAamRequestsInOrderAfterTheOriginalFive() async {
        let b = backend()
        b.alertReadDelaySecForTesting = 0.05
        var dispatched: [String] = []
        b.onReadDispatchedForTesting = { typeName, _ in dispatched.append(typeName) }
        b.startPollingForTesting()
        try? await Task.sleep(nanoseconds: 200_000_000)   // let the delayed alertRead() burst land

        // trio(3) + fastRead's 6 non-gated (op20 identity-gated) + staticRead(7) = 16, then alertRead's
        // full 7 (5 original + 2 AAM, CC-10) = 23.
        #expect(dispatched.count == 23, "trio(3)+fastRead(6)+staticRead(7)+alertRead(7) = 23")
        #expect(Array(dispatched.suffix(7)) == Self.alertReadTier,
                "alertRead() must dispatch the 2 AAM requests, in order, after the original 5 — never reordered")
    }

    // MARK: - Consumption: both responses populate the NAMED, replace-on-read backend state

    @Test func applyingBothAamResponsesPopulatesTheNamedBackendState() {
        let b = backend()
        #expect(b.highestAamForTesting == nil, "no AAM state before any response lands")
        #expect(b.activeAamBitsForTesting == nil, "no AAM state before any response lands")

        b.injectStatusFrameForTesting(FakePumpTransport.highestAamResponse(aamId: 3, faultId: 7))
        b.injectStatusFrameForTesting(
            FakePumpTransport.activeAamBitsResponse(unacknowledgedBitmask: 0b101, activeBitmask: 0b011))

        #expect(b.highestAamForTesting?.aamId == 3)
        #expect(b.highestAamForTesting?.faultId == 7)
        #expect(b.activeAamBitsForTesting?.unacknowledged == 0b101)
        #expect(b.activeAamBitsForTesting?.active == 0b011)
    }

    /// LIFECYCLE: replace-on-read, mirroring `setMalfunctionList`'s exact shape — a later response
    /// overwrites the prior value, never accumulates/merges.
    @Test func aamStateIsReplaceOnReadNotAccumulated() {
        let b = backend()
        b.injectStatusFrameForTesting(FakePumpTransport.highestAamResponse(aamId: 1, faultId: 1))
        b.injectStatusFrameForTesting(FakePumpTransport.highestAamResponse(aamId: 9, faultId: 0))
        #expect(b.highestAamForTesting?.aamId == 9,
                "a later HighestAamResponse REPLACES the prior one, mirroring setMalfunctionList's replace-on-read shape")
        #expect(b.highestAamForTesting?.faultId == 0)

        b.injectStatusFrameForTesting(FakePumpTransport.activeAamBitsResponse(unacknowledgedBitmask: 1, activeBitmask: 1))
        b.injectStatusFrameForTesting(FakePumpTransport.activeAamBitsResponse(unacknowledgedBitmask: 0, activeBitmask: 0))
        #expect(b.activeAamBitsForTesting?.unacknowledged == 0)
        #expect(b.activeAamBitsForTesting?.active == 0)
    }

    // MARK: - Boundary: AAM state is read-side only, never wired to notifications/snapshot (Phase 13)

    @Test func aamResponsesNeverTouchActiveNotificationsOrSnapshot() {
        let b = backend()
        let notificationsBefore = b.activeNotifications
        let glucoseBefore = b.snapshot.glucose

        b.injectStatusFrameForTesting(FakePumpTransport.highestAamResponse(aamId: 5, faultId: 2))
        b.injectStatusFrameForTesting(
            FakePumpTransport.activeAamBitsResponse(unacknowledgedBitmask: 0xFF, activeBitmask: 0xFF))

        #expect(b.activeNotifications.count == notificationsBefore.count,
                "AAM responses must NOT feed mergeNotifications/activeNotifications — display is Phase 13")
        #expect(b.snapshot.glucose == glucoseBefore, "AAM responses must never touch the dosing snapshot")
    }
}
