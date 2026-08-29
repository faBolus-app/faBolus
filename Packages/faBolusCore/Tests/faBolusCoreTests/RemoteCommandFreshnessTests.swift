import Testing
import Foundation
@testable import faBolusCore

/// A delivery-authorizing command that arrives too late after compose is refused (late bolus is a
/// double-dose hazard). Insulin-reducing and neutral commands are never freshness-gated; an absent stamp on a sensitive command is stale.
struct RemoteCommandFreshnessTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)  // well under the Int32.max (2038) ceiling

    /// A command of `kind` whose `sentAt` is `ageSec` before `now` (negative ageSec = stamped in the future).
    private func cmd(_ kind: RemoteCommand.Kind, ageSec: Int?) -> RemoteCommand {
        var c = RemoteCommand(kind: kind, requestId: "r")
        if let a = ageSec { c.sentAt = Int(now.timeIntervalSince1970) - a }
        return c
    }

    @Test func freshDeliveryCommandIsAccepted() {
        #expect(!RemoteCommandFreshness.isStale(cmd(.bolusRequest, ageSec: 5), now: now))
        #expect(
            !RemoteCommandFreshness.isStale(
                cmd(.bolusRequest, ageSec: Int(RemoteCommandFreshness.maxAgeSec) - 1), now: now))
    }

    @Test func staleDeliveryAuthorizingCommandsAreRejected() {
        #expect(
            RemoteCommandFreshness.isStale(
                cmd(.bolusRequest, ageSec: Int(RemoteCommandFreshness.maxAgeSec) + 1), now: now))
        #expect(RemoteCommandFreshness.isStale(cmd(.bolusRequest, ageSec: 3600), now: now))
        // The whole insulin-INCREASING set is gated, not just bolusRequest.
        #expect(RemoteCommandFreshness.isStale(cmd(.bolusConfirm, ageSec: 3600), now: now))
        #expect(RemoteCommandFreshness.isStale(cmd(.resumePump, ageSec: 3600), now: now))
        #expect(RemoteCommandFreshness.isStale(cmd(.bolusApprovalResponse, ageSec: 3600), now: now))
    }

    @Test func aStampTooFarInTheFutureIsRejected() {
        // Beyond the skew tolerance → can't trust the age → fail closed.
        #expect(
            RemoteCommandFreshness.isStale(
                cmd(.bolusRequest, ageSec: -(Int(RemoteCommandFreshness.futureSkewToleranceSec) + 5)), now: now))
        // A small future skew (clocks not perfectly aligned) is tolerated.
        #expect(!RemoteCommandFreshness.isStale(cmd(.bolusRequest, ageSec: -5), now: now))
    }

    @Test func absentStampIsStaleForFreshnessSensitive() {
        // Fail-closed: a delivery-authorizing command with no trustworthy creation time can't be
        // age-verified, so it is refused as stale (retryable) rather than trusted as fresh.
        #expect(RemoteCommandFreshness.isStale(cmd(.bolusRequest, ageSec: nil), now: now))
        // A NON-freshness-sensitive kind with no stamp stays ungated (a late cancel/status is always safe).
        #expect(!RemoteCommandFreshness.isStale(cmd(.cancelBolus, ageSec: nil), now: now))
        #expect(!RemoteCommandFreshness.isStale(cmd(.statusRead, ageSec: nil), now: now))
    }

    @Test func insulinReducingAndNeutralCommandsAreNeverGated() {
        // Even an ancient cancel/suspend/dismiss/status must NOT be refused on age — honoring a late
        // safety action (or a status read) is always safe.
        #expect(!RemoteCommandFreshness.isStale(cmd(.cancelBolus, ageSec: 3600), now: now))
        #expect(!RemoteCommandFreshness.isStale(cmd(.suspendPump, ageSec: 3600), now: now))
        #expect(!RemoteCommandFreshness.isStale(cmd(.dismissAlert, ageSec: 3600), now: now))
        #expect(!RemoteCommandFreshness.isStale(cmd(.statusRead, ageSec: 3600), now: now))
    }

    /// A request composed BEFORE the host's most recent bolus delivery is superseded (the remote dosed
    /// off pre-bolus state), so applying it now is a double-dose hazard.
    @Test func composeSupersededWhenHostDeliveredStrictlyAfterCompose() {
        #expect(
            RemoteCommandFreshness.composeSupersededByHostDelivery(
                sentAt: 1_000_000_000,
                lastHostDeliveryAt: Date(timeIntervalSince1970: 1_000_000_050)))
    }

    /// A host delivery BEFORE the compose time did not act on this request's state → not superseded.
    @Test func composeNotSupersededWhenHostDeliveredBeforeCompose() {
        #expect(
            !RemoteCommandFreshness.composeSupersededByHostDelivery(
                sentAt: 1_000_000_000,
                lastHostDeliveryAt: Date(timeIntervalSince1970: 1_000_000_000 - 50)))
    }

    /// Equal timestamps are NOT superseded — the check is strict `>`.
    @Test func composeNotSupersededWhenHostDeliveredAtExactlyComposeTime() {
        #expect(
            !RemoteCommandFreshness.composeSupersededByHostDelivery(
                sentAt: 1_000_000_000,
                lastHostDeliveryAt: Date(timeIntervalSince1970: 1_000_000_000)))
    }

    /// No compose stamp to compare against → no supersession possible (freshness + the access gate
    /// remain the other lines of defense).
    @Test func composeNotSupersededWhenSentAtIsAbsent() {
        #expect(
            !RemoteCommandFreshness.composeSupersededByHostDelivery(
                sentAt: nil,
                lastHostDeliveryAt: Date(timeIntervalSince1970: 1_000_000_050)))
    }

    /// No prior host delivery → nothing could have superseded the request.
    @Test func composeNotSupersededWhenNoPriorHostDelivery() {
        #expect(
            !RemoteCommandFreshness.composeSupersededByHostDelivery(
                sentAt: 1_000_000_000,
                lastHostDeliveryAt: nil))
    }
}
