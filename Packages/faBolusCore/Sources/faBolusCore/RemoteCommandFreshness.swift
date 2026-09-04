import Foundation

/// Receive-side freshness bound for inbound remote commands.
///
/// The send side already refuses to queue a pump-mutating command for opportunistic later delivery.
/// This closes the other end: the host refuses a **delivery-authorizing** command that arrives too
/// long after it was composed — a bolus (or resume/approval) retransmitted or backlogged by a slow
/// transport and applied minutes late is a double-dose hazard. It complements, and does not replace,
/// the idempotency ledger (which dedups *retries* of the *same* request) and the access gates.
///
/// Only `RemoteCommand.Kind.isFreshnessSensitive` commands are gated — the insulin-INCREASING set. A late
/// insulin-*reducing* command (cancel/suspend) must still be honored, so those are never rejected here.
///
/// A freshness-sensitive command with an **absent** `sentAt` is refused as stale (fail-closed, retryable):
/// a delivery-authorizing command whose age cannot be verified must not be trusted as fresh. Every
/// first-party sender stamps `sentAt`; a legacy/foreign sender that does not must resend with a stamp.
///
/// **Ordering invariant (load-bearing).** Hosts apply this gate at dispatch, *before* the idempotency
/// ledger's replay check. That is safe **only** because no transport ever late-redelivers a pump-mutating
/// command: a mutating command is sent live or reported undeliverable, never queued/retransmitted across a
/// reconnect (`transferUserInfo` never carries a bolus, and the surviving `RemoteTransport` seam reports a
/// mutating command undeliverable rather than queuing or replaying it across a reconnect), and no client auto-resends a
/// pending bolus with its *original* `requestId`/`sentAt` (`startPending` always mints a fresh stamp). So a
/// genuinely stale command and a ledger-replayable one are mutually exclusive. If a future transport is
/// ever allowed to re-queue a mutating command, move the ledger's `.replay` check AHEAD of this gate so a
/// request whose outcome is already known replays its result instead of being refused as stale (which
/// would otherwise push the user toward a manual re-dose).
public enum RemoteCommandFreshness {
    /// Maximum age of a delivery-authorizing command before the host refuses it. Generous relative to
    /// normal transport latency (sub-second to a few seconds) yet well under the "minutes late" hazard the
    /// bound exists to catch, leaving comfortable headroom for modest sender↔host clock skew (the stamp is
    /// the *sender's* wall clock; the host compares against its own).
    public static let maxAgeSec: TimeInterval = 120
    /// A stamp more than this far in the *future* is treated as skew/garbage and also refused (fail-closed):
    /// a delivery command whose age can't be trusted must not be applied.
    public static let futureSkewToleranceSec: TimeInterval = 30

    /// Whether an inbound command must be refused as stale. For a freshness-sensitive (insulin-INCREASING)
    /// kind: `true` when `sentAt` is absent (age can't be verified — fail closed, retryable) OR present but
    /// outside the acceptable window. Non-sensitive kinds are never gated, so this is safe to call
    /// unconditionally at a host's dispatch entry.
    public static func isStale(_ command: RemoteCommand, now: Date = Date()) -> Bool {
        guard command.kind.isFreshnessSensitive else { return false }
        // Fail-closed: a delivery-authorizing command with no trustworthy creation time cannot be
        // age-verified, so it is refused (retryable) rather than trusted as fresh. Every first-party
        // sender stamps `sentAt`; a legacy/foreign sender that does not must resend with a stamp.
        guard let sentAt = command.sentAt else { return true }
        let age = now.timeIntervalSince1970 - Double(sentAt)
        return age > maxAgeSec || age < -futureSkewToleranceSec
    }

    /// User-facing reason for a refused-as-stale command (shown on the remote that sent it).
    public static let rejectionMessage =
        "This request is too old to apply safely — send it again."

    /// True when a remote request composed at `sentAt` predates the host's most recent
    /// bolus delivery — the remote dosed off pre-bolus state, so applying it now is a double-dose hazard.
    /// Absent `sentAt` or no prior host delivery ⇒ false (no supersession possible; freshness + the
    /// access gate remain the other lines of defense). Both sides are wall-clock Unix seconds.
    public static func composeSupersededByHostDelivery(sentAt: Int?, lastHostDeliveryAt: Date?) -> Bool {
        guard let sentAt, let last = lastHostDeliveryAt else { return false }
        return last.timeIntervalSince1970 > Double(sentAt)
    }
}
