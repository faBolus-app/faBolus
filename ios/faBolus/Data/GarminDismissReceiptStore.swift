import Foundation

/// CX-G-08 (14-09, H2/HIGH-A/T-14-30) — a durable authenticated-dismiss RECEIPT: proof that a
/// Garmin-initiated dismiss `(peer, requestId, alertId, alertKind)` was CC-08 pump-cleared
/// (`.authenticatedCleared`). Persisted at the BRIDGE layer, NOT inside `TandemBackend
/// .dismissNotificationTyped` — the typed method sees only a `PumpAlert` (no peer, no requestId), so it
/// literally cannot key a receipt; `cmd.requestId` exists only where `GarminRemoteBridge` reads the
/// incoming `RemoteCommand`. This is why the receipt moves one layer up from the backend.
///
/// Lane 1 (RETRY/PENDING) from the plan's two-lane lifecycle block, phone side: a named TTL WELL under
/// the pump's 30-min re-nag window, capped, oldest-pruned. Pruning removes NO alert on the watch — it
/// only stops this phone-side replay lane from answering a very-late/duplicate retry; the watch's own
/// retry lane (AppState.mc) has the matching TTL and simply stops resending once its own entry expires.
///
/// EXEMPT from `GarminRemoteBridge`'s bolus `garminEchoedRequestIds` set (T-14-32/MEDIUM-F) — a
/// completely separate `UserDefaults` key, so a dismiss receipt can never evict (or be evicted by) a
/// bolus echo's 256-entry durable set.
struct GarminDismissReceipt: Codable, Equatable {
    let peer: String
    let requestId: String
    let alertId: Int
    let alertKind: Int
    let createdAt: Date
    /// Whether the correlated `dismissAck` was actually handed to the send queue for this receipt yet.
    /// `false` until the bridge sends it; the launch-time seed (mirrors
    /// `GarminRemoteBridge.seedTerminalEchoesFromLedger`) resends any receipt still `false` so a phone
    /// death between persist and send does not silently strand the ack forever.
    var acked: Bool
}

/// ConnectIQ-free durable outbox of authenticated dismiss receipts (mirrors
/// `GarminRemoteBridge.alreadyEchoedRequestIds`'s durability pattern on its OWN, separate lane — never
/// touching `garminEchoedRequestIds`). Unit-testable in the default (non-GARMIN) target, matching
/// `garminEchoesToSeed`/`GarminMessageReadiness`'s own ConnectIQ-free placement.
// @unchecked Sendable: the ONLY stored state is an immutable `let defaults: UserDefaults` (itself
// thread-safe/Sendable) and a `let defaultsKey: String` — every "mutation" is a UserDefaults
// read/write, never in-memory mutable state on this type itself. Safe for the `static let shared`
// singleton under Swift 6 strict concurrency.
final class GarminDismissReceiptStore: @unchecked Sendable {
    static let shared = GarminDismissReceiptStore()

    /// Named TTL WELL under the pump's 30-min re-nag window (TandemBackend.swift, `snoozeWindow`) — the
    /// plan's two-lane lifecycle block picks 10 minutes as the concrete example; both watch and phone
    /// lanes use the SAME window so the two ends stop correlating together.
    static let ttl: TimeInterval = 10 * 60
    /// Bounded outbox (oldest pruned) — mirrors `alreadyEchoedCap`'s bounded-growth discipline.
    static let cap = 32

    private let defaults: UserDefaults
    private let defaultsKey = "garminDismissReceipts"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Persist a receipt SYNCHRONOUSLY (no await) — called the INSTANT `.authenticatedCleared` is
    /// observed, BEFORE the correlated `dismissAck` is sent. The gap between the pump's authenticated
    /// clear and this call completing is the plan's documented FAIL-CLOSED crash window: if the phone
    /// dies there, no receipt exists, and the watch's own durable overlay simply stays visible and
    /// keeps retrying — never fail-open. Replaces any existing receipt for the same (peer, requestId) —
    /// a lost-ack RETRY reuses the identical requestId, so this is naturally idempotent.
    func persist(peer: String, requestId: String, alertId: Int, alertKind: Int, now: Date = Date()) {
        var all = allReceipts()
        all.removeAll { $0.peer == peer && $0.requestId == requestId }
        all.append(GarminDismissReceipt(peer: peer, requestId: requestId, alertId: alertId,
                                        alertKind: alertKind, createdAt: now, acked: false))
        if all.count > Self.cap { all.removeFirst(all.count - Self.cap) }
        save(all)
    }

    /// Mark a receipt's ack as actually sent (handed to the outbound queue). A launch-time reseed only
    /// resends receipts still `false`.
    func markAcked(peer: String, requestId: String) {
        var all = allReceipts()
        guard let idx = all.firstIndex(where: { $0.peer == peer && $0.requestId == requestId }) else { return }
        all[idx].acked = true
        save(all)
    }

    /// Look up an UNEXPIRED receipt by `(peer, requestId)` for REPLAY — the bridge calls this BEFORE
    /// `AppModel.dismissAlert`'s missing-alert guard, so a retry that reuses the same requestId after
    /// the alert has already been filtered out of `activeNotifications` still gets its ack replayed
    /// (H2/HIGH-A) instead of silently falling through the guard with no re-ack. Pruned lazily on read
    /// (mirrors the two-lane lifecycle block's "MAY expire and MAY be pruned" for the retry lane).
    func receipt(peer: String, requestId: String, now: Date = Date()) -> GarminDismissReceipt? {
        pruneExpired(now: now).first { $0.peer == peer && $0.requestId == requestId }
    }

    /// Every receipt whose ack was never sent (crash window between persist and send) — the launch-time
    /// analogue of `garminEchoesToSeed`, so a phone death in that window is recovered proactively rather
    /// than waiting on the watch's own bounded retry.
    func unackedReceipts(now: Date = Date()) -> [GarminDismissReceipt] {
        pruneExpired(now: now).filter { !$0.acked }
    }

    /// Drop expired (`now - createdAt >= ttl`) AND clock-rolled (future `createdAt`) entries — the
    /// plan's clock-rollback discipline treats a future timestamp as invalid/expired on this lane too
    /// (pruning removes no ALERT; the watch's own display-provisional overlay is a separate lane that is
    /// NEVER pruned by expiry — see AppState.mc). Persists the pruned set back if anything changed.
    @discardableResult
    private func pruneExpired(now: Date) -> [GarminDismissReceipt] {
        let all = allReceipts()
        let kept = all.filter { r in
            let elapsed = now.timeIntervalSince(r.createdAt)
            return elapsed >= 0 && elapsed < Self.ttl
        }
        if kept.count != all.count { save(kept) }
        return kept
    }

    private func allReceipts() -> [GarminDismissReceipt] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([GarminDismissReceipt].self, from: data)) ?? []
    }

    private func save(_ receipts: [GarminDismissReceipt]) {
        guard let data = try? JSONEncoder().encode(receipts) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Test-only: wipe the store (mirrors a fresh install / no prior receipts).
    func removeAllForTesting() { defaults.removeObject(forKey: defaultsKey) }
}
