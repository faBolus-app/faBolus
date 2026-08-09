import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P16 F7 — the in-memory BLE-session ring buffer for the in-app debug console. It must stay a no-op
/// until the user opts in (default OFF, shared diagnostics flag), record events in order when on, and be
/// bounded to `capacity` (dropping the oldest). Mirrors `ConnectionTelemetryStoreTests` (injected
/// UserDefaults suite carrying the shared opt-in flag). In-memory only — nothing is persisted.
@MainActor
struct BLESessionLogTests {

    /// A private in-memory suite per test, carrying whether the shared diagnostics opt-in is on.
    private func makeLog(enabled: Bool, capacity: Int = 100) -> (BLESessionLog, UserDefaults) {
        let suite = "ble-log-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(enabled, forKey: NotificationRuntime.telemetryEnabledKey)
        return (BLESessionLog(capacity: capacity, store: d), d)
    }

    @Test func disabledByDefaultIsNoOp() {
        let (log, _) = makeLog(enabled: false)
        log.record(.connect)
        log.record(.disconnect, detail: "btOff")
        log.record(.reconnect)
        #expect(log.entries.isEmpty)
    }

    @Test func enabledRecordsInChronologicalOrderWithDetail() {
        let (log, _) = makeLog(enabled: true)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        log.record(.connect, at: t0)
        log.record(.disconnect, detail: "btOff", at: t0.addingTimeInterval(60))
        log.record(.reconnect, at: t0.addingTimeInterval(120))
        #expect(log.entries.count == 3)
        #expect(log.entries.first?.kind == .connect)
        #expect(log.entries[1].kind == .disconnect)
        #expect(log.entries[1].detail == "btOff")
        #expect(log.entries.last?.kind == .reconnect)
    }

    @Test func boundedToCapacityDroppingOldest() {
        let (log, _) = makeLog(enabled: true, capacity: 3)
        for i in 0..<10 { log.record(.disconnect, detail: "\(i)") }
        #expect(log.entries.count == 3)
        // Oldest-first buffer keeps the last 3 (7, 8, 9); 0…6 were dropped.
        #expect(log.entries.first?.detail == "7")
        #expect(log.entries.last?.detail == "9")
    }

    @Test func clearEmptiesTheBuffer() {
        let (log, _) = makeLog(enabled: true)
        log.record(.connect)
        log.record(.disconnect, detail: "dropped")
        log.clear()
        #expect(log.entries.isEmpty)
    }

    /// Capacity is clamped to at least 1 so a degenerate `0` can't wedge the trim math.
    @Test func capacityClampedToAtLeastOne() {
        let (log, _) = makeLog(enabled: true, capacity: 0)
        log.record(.connect)
        log.record(.disconnect)
        #expect(log.capacity == 1)
        #expect(log.entries.count == 1)
        #expect(log.entries.last?.kind == .disconnect)
    }
}
