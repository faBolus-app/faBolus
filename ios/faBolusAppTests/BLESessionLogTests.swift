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

    // MARK: - D-04 connectDurations(from:)

    /// Each `.connect`/`.reconnect`/`.restore` opens a span; the NEXT `.disconnect` closes it, pairing
    /// purely off the existing `Entry.at` timestamps — no new `Kind` case, no new stored field.
    @Test func connectDurationsPairsEachOpenSpanWithNextDisconnect() {
        let (log, _) = makeLog(enabled: true)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let t1 = t0.addingTimeInterval(1_000)
        log.record(.connect, at: t0)
        log.record(.disconnect, detail: "btOff", at: t0.addingTimeInterval(30))
        log.record(.reconnect, at: t1)
        log.record(.disconnect, detail: "btOff", at: t1.addingTimeInterval(5))

        let spans = BLESessionLog.connectDurations(from: log.entries)
        #expect(spans.count == 2)
        #expect(spans[0].end.timeIntervalSince(spans[0].start) == 30)
        #expect(spans[1].end.timeIntervalSince(spans[1].start) == 5)
    }

    /// A trailing open span (a `.connect`/`.reconnect`/`.restore` with no following `.disconnect` yet) is
    /// still "connected" — it is NOT emitted as a closed span by this helper.
    @Test func connectDurationsDropsTrailingOpenSpan() {
        let (log, _) = makeLog(enabled: true)
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        log.record(.connect, at: t0)
        log.record(.disconnect, at: t0.addingTimeInterval(10))
        log.record(.reconnect, at: t0.addingTimeInterval(20))

        let spans = BLESessionLog.connectDurations(from: log.entries)
        #expect(spans.count == 1)
        #expect(spans[0].end.timeIntervalSince(spans[0].start) == 10)
    }

    /// A `.disconnect` with no open span (no preceding connect/reconnect/restore) is ignored, not paired
    /// with anything.
    @Test func connectDurationsIgnoresDisconnectWithNoOpenSpan() {
        let (log, _) = makeLog(enabled: true)
        let t0 = Date(timeIntervalSince1970: 4_000_000)
        log.record(.disconnect, at: t0)
        log.record(.connect, at: t0.addingTimeInterval(5))
        log.record(.disconnect, at: t0.addingTimeInterval(15))

        let spans = BLESessionLog.connectDurations(from: log.entries)
        #expect(spans.count == 1)
        #expect(spans[0].end.timeIntervalSince(spans[0].start) == 10)
    }

    // MARK: - D-02b (09.6-02): ring buffer's presence in the export projection

    /// `DebugMenuView.bleSessionLogExportLines` — the exact `[BLE session log]` line-builder that feeds
    /// `diagnosticsText` (extracted to a pure, testable static so the export contents can be asserted
    /// without instantiating the View, mirroring `CapabilityDiagnostics.section`). Every recorded entry
    /// (well under capacity) must appear in the export projection — not silently dropped.
    @Test func exportProjectionContainsEntriesUpToCapacity() {
        let (log, _) = makeLog(enabled: true, capacity: 5)
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        for i in 0..<5 {
            log.record(.disconnect, detail: "d\(i)", at: t0.addingTimeInterval(Double(i)))
        }
        #expect(log.entries.count == 5)
        let block = DebugMenuView.bleSessionLogExportLines(entries: log.entries, capacity: log.capacity)
        for i in 0..<5 {
            #expect(block.contains("d\(i)"), "entry d\(i) missing from the export projection")
        }
    }

    /// A full ring buffer (more events recorded than `capacity`) keeps exactly the `capacity`
    /// most-recent entries in the export projection — the oldest are dropped, never all of it (never
    /// zero), matching `boundedToCapacityDroppingOldest`'s ring semantics.
    @Test func exportProjectionKeepsMostRecentCapacityEntriesWhenOverCapacity() {
        let (log, _) = makeLog(enabled: true, capacity: 3)
        let t0 = Date(timeIntervalSince1970: 6_000_000)
        for i in 0..<10 {
            log.record(.disconnect, detail: "d\(i)", at: t0.addingTimeInterval(Double(i)))
        }
        #expect(log.entries.count == 3)

        let block = DebugMenuView.bleSessionLogExportLines(entries: log.entries, capacity: log.capacity)
        #expect(block.contains("d7"))
        #expect(block.contains("d8"))
        #expect(block.contains("d9"))
        #expect(!block.contains("d0"))
        #expect(!block.contains("d6"))
    }

    /// The opt-in being off means `record` never appended anything (already pinned by
    /// `disabledByDefaultIsNoOp`) — the export projection for an empty buffer renders the shared
    /// empty-state line, never a blank/absent section.
    @Test func exportProjectionEmptyStateWhenOptInIsOff() {
        let (log, _) = makeLog(enabled: false, capacity: 100)
        log.record(.connect)
        log.record(.disconnect, detail: "btOff")
        #expect(log.entries.isEmpty)

        let block = DebugMenuView.bleSessionLogExportLines(entries: log.entries, capacity: log.capacity)
        #expect(block.contains("[BLE session log]"))
        #expect(block.contains("—"))
    }
}
