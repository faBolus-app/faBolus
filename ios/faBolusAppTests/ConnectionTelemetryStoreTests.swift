import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P12 §5.2.8 / N21 — the opt-in connection telemetry store: it must stay a no-op until the user opts
/// in (default OFF), accrue uptime + bucket disconnect reasons + count reconciliation outcomes when on,
/// and read-modify-write so a sibling process can't clobber it. Mirrors the P9 telemetry test style
/// (injected UserDefaults suite).
@MainActor
struct ConnectionTelemetryStoreTests {

    /// A private in-memory suite per test, and whether the shared diagnostics opt-in is on.
    private func makeStore(enabled: Bool) -> (ConnectionTelemetryStore, UserDefaults) {
        let suite = "ct-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(enabled, forKey: NotificationRuntime.telemetryEnabledKey)
        return (ConnectionTelemetryStore(store: d), d)
    }

    @Test func disabledByDefaultIsNoOp() {
        let (s, _) = makeStore(enabled: false)
        s.recordConnected(at: Date())
        s.recordDisconnected(reason: "btOff", at: Date())
        s.recordReconciliation(.delivered)
        let t = s.snapshot
        #expect(t.connectCount == 0)
        #expect(t.totalUptimeSeconds == 0)
        #expect(t.disconnects.isEmpty)
        #expect(t.reconcile.isEmpty)
    }

    @Test func enabledAccruesConnectCountAndUptimeAndReason() {
        let (s, _) = makeStore(enabled: true)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        s.recordConnected(at: t0)
        s.recordDisconnected(reason: "btOff", at: t0.addingTimeInterval(120))
        let t = s.snapshot
        #expect(t.connectCount == 1)
        #expect(t.totalUptimeSeconds == 120)
        #expect(t.disconnects["btOff"] == 1)
    }

    @Test func reconciliationCountsByOutcome() {
        let (s, _) = makeStore(enabled: true)
        s.recordReconciliation(.delivered)
        s.recordReconciliation(.delivered)
        s.recordReconciliation(.cancelled)
        s.recordReconciliation(.notDelivered)
        let t = s.snapshot
        #expect(t.reconcile["delivered"] == 2)
        #expect(t.reconcile["cancelled"] == 1)
        #expect(t.reconcile["notDelivered"] == 1)
    }

    @Test func reasonTokenBucketsConnectionDetail() {
        #expect(ConnectionTelemetryStore.reasonToken(from: nil) == "dropped")
        #expect(ConnectionTelemetryStore.reasonToken(from: "Bluetooth is off") == "btOff")
        #expect(ConnectionTelemetryStore.reasonToken(from: "Bluetooth permission denied — enable it in Settings") == "unauthorized")
        #expect(ConnectionTelemetryStore.reasonToken(from: "Bluetooth unavailable on this device") == "unsupported")
        #expect(ConnectionTelemetryStore.reasonToken(from: "Bluetooth is resetting…") == "resetting")
        #expect(ConnectionTelemetryStore.reasonToken(from: "Peer removed pairing") == "error")
    }

    /// D-03 — a CBError-shaped detail (`TandemBackend.applyClientError`'s enriched
    /// `"\(domain)#\(code) \(description)"` format) must bucket on its `domain#code` prefix instead of
    /// collapsing into the generic "error" token; the four pre-existing string-matched inputs above are
    /// unaffected (re-asserted here so a regression in the fallback ordering fails loudly).
    @Test func reasonTokenBucketsCBErrorDomainCodeInsteadOfGenericError() {
        let token = ConnectionTelemetryStore.reasonToken(
            from: "CBErrorDomain#6 The connection has timed out unexpectedly.")
        #expect(token != "error")
        #expect(token == "CBErrorDomain#6")
        // Pre-existing branches still win over the new fallback (unchanged behavior).
        #expect(ConnectionTelemetryStore.reasonToken(from: "Bluetooth is off") == "btOff")
        #expect(ConnectionTelemetryStore.reasonToken(from: "Bluetooth permission denied — enable it in Settings") == "unauthorized")
        #expect(ConnectionTelemetryStore.reasonToken(from: "Bluetooth unavailable on this device") == "unsupported")
        #expect(ConnectionTelemetryStore.reasonToken(from: "Bluetooth is resetting…") == "resetting")
    }

    // MARK: - B3a: command-latency dimension

    @Test func commandLatencyBucketsResponsesAndTimeouts() {
        let (s, _) = makeStore(enabled: true)
        s.recordCommandLatency(0.30)   // → lt500ms
        s.recordCommandLatency(0.31)   // → lt500ms
        s.recordCommandLatency(1.5)    // → lt2s
        s.recordCommandLatency(nil)    // → timeout
        let t = s.snapshot
        #expect(t.commandLatency["lt500ms"] == 2)
        #expect(t.commandLatency["lt2s"] == 1)
        #expect(t.commandLatency["timeout"] == 1)
    }

    @Test func commandLatencyIsNoOpWhenDisabled() {
        let (s, _) = makeStore(enabled: false)
        s.recordCommandLatency(0.3)
        s.recordCommandLatency(nil)
        #expect(s.snapshot.commandLatency.isEmpty)
    }

    @Test func latencyBucketEdges() {
        #expect(ConnectionTelemetry.latencyBucket(0.0) == "lt250ms")
        #expect(ConnectionTelemetry.latencyBucket(0.249) == "lt250ms")
        #expect(ConnectionTelemetry.latencyBucket(0.25) == "lt500ms")
        #expect(ConnectionTelemetry.latencyBucket(0.999) == "lt1s")
        #expect(ConnectionTelemetry.latencyBucket(1.0) == "lt2s")
        #expect(ConnectionTelemetry.latencyBucket(3.999) == "lt4s")
        #expect(ConnectionTelemetry.latencyBucket(4.0) == "ge4s")
        #expect(ConnectionTelemetry.latencyBucket(30) == "ge4s")
    }

    /// MIGRATION GUARD (B3a): a P12 blob persisted BEFORE `commandLatency` existed (no such key) must
    /// upgrade in place — the shipped connect/uptime/disconnect/reconcile counters MUST survive, not reset
    /// to zero. Regression pin for the synthesized-Codable hazard (a missing non-optional key would throw →
    /// `try? decode` → zeroed telemetry).
    @Test func oldBlobWithoutCommandLatencyPreservesCounters() throws {
        let suite = "ct-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(true, forKey: NotificationRuntime.telemetryEnabledKey)
        // A pre-B3a JSON payload — note: NO `commandLatency` key.
        let old = #"{"connectCount":3,"totalUptimeSeconds":600,"disconnects":{"btOff":2},"reconcile":{"delivered":1}}"#
        d.set(Data(old.utf8), forKey: "connectionTelemetry.v1")

        let t = ConnectionTelemetryStore(store: d).snapshot
        #expect(t.connectCount == 3)                 // preserved, not zeroed
        #expect(t.totalUptimeSeconds == 600)
        #expect(t.disconnects["btOff"] == 2)
        #expect(t.reconcile["delivered"] == 1)
        #expect(t.commandLatency.isEmpty)            // new field defaults empty

        // …and a subsequent latency record composes with the migrated blob.
        let s = ConnectionTelemetryStore(store: d)
        s.recordCommandLatency(0.1)
        let t2 = s.snapshot
        #expect(t2.connectCount == 3)                // still there after the write
        #expect(t2.commandLatency["lt250ms"] == 1)
    }

    /// Two stores on the same suite must not clobber each other's counters (read-modify-write).
    @Test func readModifyWriteDoesNotClobberAcrossStores() {
        let suite = "ct-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(true, forKey: NotificationRuntime.telemetryEnabledKey)
        let a = ConnectionTelemetryStore(store: d)
        let b = ConnectionTelemetryStore(store: d)
        a.recordConnected(at: Date())            // writes connectCount = 1
        b.recordReconciliation(.delivered)       // must preserve connectCount while adding reconcile
        let t = ConnectionTelemetryStore(store: d).snapshot
        #expect(t.connectCount == 1)
        #expect(t.reconcile["delivered"] == 1)
    }
}
