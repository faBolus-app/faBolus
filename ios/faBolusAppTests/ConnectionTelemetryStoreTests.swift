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
