import Foundation

/// Receive-side freshness bound for a remote's insulin request.
///
/// The host refuses a request that arrives too long after it was composed: a bolus retransmitted or
/// backlogged by a slow transport and applied minutes late is a double-dose hazard. It complements, and
/// does not replace, the idempotency ledger (which dedups *retries* of the *same* request) and the access
/// gates.
///
/// A request with an **absent** send time is refused as stale (fail-closed, retryable): a request whose
/// age cannot be verified must not be trusted as fresh.
///
/// **Ordering.** `DoseComposer.composeRemote` answers a request the ledger already holds before this
/// check, so a resend whose outcome is known gets that outcome back rather than a stale-request refusal.
public enum RemoteRequestFreshness {
    /// Maximum age of an insulin request before the host refuses it. Generous relative to normal transport
    /// latency (sub-second to a few seconds) yet well under the "minutes late" hazard the bound exists to
    /// catch, leaving comfortable headroom for modest sender↔host clock skew (the stamp is the *sender's*
    /// wall clock; the host compares against its own).
    public static let maxAgeSec: TimeInterval = 120
    /// A stamp more than this far in the *future* is treated as skew/garbage and also refused (fail-closed):
    /// a request whose age can't be trusted must not be applied.
    public static let futureSkewToleranceSec: TimeInterval = 30

    /// Whether an insulin request sent at `sentAt` must be refused as stale: no send time, older than
    /// `maxAgeSec`, or dated further than `futureSkewToleranceSec` ahead.
    public static func isStale(sentAt: Date?, now: Date = Date()) -> Bool {
        guard let sentAt, sentAt.timeIntervalSince1970.isFinite else { return true }
        let age = now.timeIntervalSince(sentAt)
        return !age.isFinite || age > maxAgeSec || age < -futureSkewToleranceSec
    }

    /// User-facing reason for a request refused as stale (shown on the remote that sent it).
    public static let rejectionMessage =
        "This request is too old to apply safely — send it again."
}
