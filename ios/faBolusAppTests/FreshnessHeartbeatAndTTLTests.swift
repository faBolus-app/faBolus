import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P10 (defect group A, R2 follow-ups) — the two aging/liveness fixes that keep a *silent* link and a
/// *killed host* from ever presenting stale state as live.
///
/// WR-01 (R2-08, f28a767): `AppModel.init` now arms the ~20 s `arbiterTimer` `refresh()` heartbeat
/// UNCONDITIONALLY (was armed only inside the failover-CGM branch), so the default pump-only config also
/// has a periodic driver for the aging work — the §6 CGM-data-loss edge, the widget publish/App-Group
/// re-stamp, and staleness re-eval — even when a connected-but-silent pump never fires `source.onChange`.
///
/// WR-02 (R2-09, 779db47): a killed host leaves its last snapshot persisted in the App Group, so
/// `snap.connected` alone would read "connected" forever. `WidgetSnapshot.isConnectionStale(asOf:)`
/// (keyed off `updatedAt`, the PUBLISH time — not `glucoseDate`, the sample time) ages the connection
/// flag + the dateless pump metrics past `connectionStaleAfter` (6 min), so the widgets treat a
/// no-longer-republishing snapshot as not-connected.
///
/// Coverage split:
///  • The widget TTL is a pure value-layer guarantee (deterministic) and is pinned directly here.
///  • The heartbeat's ARMING itself is not unit-observable (no injected clock, no timer spy). What IS
///    observable is the *effect* of the call the timer (and foreground-resume) make — `publicRefresh()`
///    → the same private `refresh()` — so we assert that path's aging behavior: it raises `.cgmDataLoss`
///    on a fresh→stale transition, fires once (no re-raise on a steady stale state, so a 20 s tick can't
///    spam), and is a safe no-op on a cold `.disconnected` model. See the note on the gap in
///    `heartbeatRefreshPathIsSafeAndSilentOnAColdDisconnectedModel`.
@MainActor
@Suite(.serialized) struct FreshnessHeartbeatAndTTLTests {

    /// A unique durable-ledger URL so serialized `AppModel` instances don't share the App-Group ledger and
    /// a stray reconciliation post can't leak into a sink (same isolation `SafetyNotificationTests` uses).
    private func tempLedgerURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("freshness-ttl-ledger-\(UUID().uuidString).json")
    }

    // MARK: - WR-02 (R2-09): widget connection TTL (pure value layer — the most deterministic)

    /// The keystone WR-02 assertion: connection freshness keys off `updatedAt` (the PUBLISH time), NOT
    /// `glucoseDate` (the sample time). A killed host leaves a snapshot whose SAMPLE is recent but whose
    /// last PUBLISH is old — that must read connection-stale, because nothing is re-stamping `updatedAt`.
    /// A brand-new publish (fresh `updatedAt`) reads connection-fresh even when nothing else changed.
    /// (Snapshot construction mirrors `CrossSurfaceStalenessTests` — explicit `updatedAt` vs `glucoseDate`.)
    @Test func connectionStalenessKeysOffPublishTimeNotSampleTime() {
        let now = Date()
        let ttl = WidgetSnapshot.connectionStaleAfter

        // Host killed: sample taken 30 s ago (fresh), but the last publish is well past the TTL.
        let hostKilled = WidgetSnapshot(
            glucose: 120, glucoseDate: now.addingTimeInterval(-30),
            connected: true, updatedAt: now.addingTimeInterval(-(ttl + 60)))
        #expect(hostKilled.isConnectionStale(asOf: now))  // off updatedAt (>6 min), NOT glucoseDate (30 s)

        // A live host that just published: same recent sample, but a fresh `updatedAt` → connection-fresh.
        let live = WidgetSnapshot(
            glucose: 120, glucoseDate: now.addingTimeInterval(-30),
            connected: true, updatedAt: now)
        #expect(!live.isConnectionStale(asOf: now))
    }

    /// The TTL constant is the documented 6 min (mirrors the glucose stale window, so normal operation —
    /// well within the ~20 s publish heartbeat — never trips it), and the boundary uses a strict `>` so a
    /// snapshot exactly at the TTL is not yet stale. Margins avoid float-cancellation flake at the edge.
    @Test func connectionTTLConstantAndBoundary() {
        let now = Date()
        #expect(WidgetSnapshot.connectionStaleAfter == 6 * 60)
        let ttl = WidgetSnapshot.connectionStaleAfter

        // Just inside the window → still fresh.
        let justFresh = WidgetSnapshot(
            glucose: 120, connected: true,
            updatedAt: now.addingTimeInterval(-(ttl - 5)))
        #expect(!justFresh.isConnectionStale(asOf: now))
        // Just past the window → stale.
        let justStale = WidgetSnapshot(
            glucose: 120, connected: true,
            updatedAt: now.addingTimeInterval(-(ttl + 5)))
        #expect(justStale.isConnectionStale(asOf: now))
    }

    /// WR-02 render/logic boundary. The widget views expose no unit seam, so the two predicates they use
    /// are reproduced verbatim from the source and pinned against a stale-connection snapshot:
    ///   • `QuickBolusView.isConnected  = snap.connected && !snap.isConnectionStale(asOf:)` — the confirm
    ///     pad is enabled only when this is true, so a killed-host snapshot disables the pad even though
    ///     `snap.connected` is still `true`.
    ///   • `StatusWidgetView.connectionStale = snap.isConnectionStale(asOf:)` — greys the dateless
    ///     iob/reservoir/battery metrics to "--" once true.
    /// The positive control (a fresh publish) keeps both predicates in the connected/not-grey state, so
    /// the stale assertions aren't vacuous.
    @Test func staleConnectionSnapshotIsTreatedAsNotConnectedByBothWidgetPredicates() {
        let now = Date()
        let ttl = WidgetSnapshot.connectionStaleAfter

        let stale = WidgetSnapshot(
            glucose: 120, glucoseDate: now.addingTimeInterval(-30),
            connected: true, updatedAt: now.addingTimeInterval(-(ttl + 60)))
        // QuickBolusView.isConnected
        #expect(!(stale.connected && !stale.isConnectionStale(asOf: now)))  // pad disabled despite connected==true
        // StatusWidgetView.connectionStale
        #expect(stale.isConnectionStale(asOf: now))  // dateless metrics grey to "--"

        let fresh = WidgetSnapshot(
            glucose: 120, glucoseDate: now.addingTimeInterval(-30),
            connected: true, updatedAt: now)
        #expect(fresh.connected && !fresh.isConnectionStale(asOf: now))  // pad enabled
        #expect(!fresh.isConnectionStale(asOf: now))  // metrics shown
    }

    // MARK: - WR-01/WR-02: the heartbeat/foreground refresh path (real seam, best-effort)

    /// WR-01 core: on the default pump-only config (NO failover glucose source) the aging work is driven
    /// by the `refresh()` path the heartbeat + foreground-resume invoke. `publicRefresh()` is that exact
    /// path (a public wrapper over the private `refresh()`), so it re-evaluates freshness against the
    /// current state and raises the never-suppressible §6 `.cgmDataLoss` on a fresh→stale transition.
    ///
    /// A previously-fresh feed (a fresh reading, driven in via the backend's own `onChange`) then going
    /// stale must post exactly ONE `.cgmDataLoss`. Critically, a SUBSEQUENT `publicRefresh()` — a bare
    /// heartbeat tick with no new source data — must NOT re-raise the steady stale state: the notification
    /// fires once on the edge, so a 20 s heartbeat can never spam it. (`seedFreshGlucose` is the only
    /// public backend mutator and it fires `onChange`; the transition itself therefore lands on the
    /// onChange-driven `refresh()`, but that is the identical private method the heartbeat calls, and the
    /// trailing `publicRefresh()` proves the heartbeat re-runs the path idempotently.)
    @Test func refreshPathRaisesCgmDataLossOnceOnFreshToStaleAndHeartbeatDoesNotReRaise() {
        let backend = MockBackend()
        let model = AppModel(source: backend, ledgerStoreURL: tempLedgerURL())
        var posted: [NotificationBroker.Message] = []
        model.notificationSink = { msg, _, _ in posted.append(msg) }

        // Previously fresh: a live reading arrives → refresh sees fresh (freshness edge false→true = clear).
        backend.seedFreshGlucose(120, at: Date())
        #expect(posted.filter { $0.category == .cgmDataLoss }.isEmpty)  // no loss while fresh

        // Feed goes stale (a reading dated an hour ago): the fresh→stale edge raises exactly one loss.
        backend.seedFreshGlucose(120, at: Date().addingTimeInterval(-3600))
        let losses = posted.filter { $0.category == .cgmDataLoss }
        #expect(losses.count == 1)
        #expect(losses.first?.title == "CGM data lost")
        #expect(losses.first?.dedupeKey == "safety.cgmDataLoss")

        // A bare heartbeat/foreground tick (no new source data) re-runs the aging path but must NOT
        // re-raise a steady stale state — fire-once-on-edge, so the ~20 s timer can't spam.
        model.publicRefresh()
        #expect(posted.filter { $0.category == .cgmDataLoss }.count == 1)
    }

    /// WR-01 safety: the unconditional heartbeat must be harmless on a cold, `.disconnected`, pump-only
    /// model. `publicRefresh()` (the heartbeat/foreground call) issues no BLE read — its only outbound
    /// action, `maybeAutoSyncPumpTime()`, is self-gated on `snapshot.connection == .connected` (verified in
    /// source) and so no-ops here — and posts NO spurious safety notification: startup down is not a
    /// pump-drop (`SafetyEdge.connection(prev: nil, now: .disconnected) == .none`) and a never-fresh feed
    /// is not data-loss (`freshness(false, false) == .none`). Repeated ticks stay silent and never connect.
    ///
    /// GAP: the 20 s timer's arming is not directly unit-observable (no injected clock / timer spy); this
    /// asserts the *effect* of the call it makes rather than the fire. The default `MockBackend()` seed is
    /// deliberately stale + `.disconnected`, exactly a just-launched pump-only user before the first frame.
    @Test func heartbeatRefreshPathIsSafeAndSilentOnAColdDisconnectedModel() {
        let backend = MockBackend()
        let model = AppModel(source: backend, ledgerStoreURL: tempLedgerURL())
        #expect(model.snapshot.connection == .disconnected)  // precondition: cold pump-only launch

        var posted: [NotificationBroker.Message] = []
        model.notificationSink = { msg, _, _ in posted.append(msg) }

        model.publicRefresh()
        model.publicRefresh()

        #expect(posted.filter { $0.category == .cgmDataLoss }.isEmpty)  // no data-loss (never was fresh)
        #expect(posted.filter { $0.category == .pumpDisconnect }.isEmpty)  // cold-down is not a drop
        #expect(model.snapshot.connection == .disconnected)  // no BLE connect attempt issued
    }
}
