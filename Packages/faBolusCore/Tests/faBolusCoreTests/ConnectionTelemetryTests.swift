import Testing
import Foundation
@testable import faBolusCore

/// `ConnectionTelemetry`'s hand-written `Codable` conformance is the house safe-decode pattern: every
/// persisted blob predates at least one field this type has since gained, so every field decodes with
/// `decodeIfPresent` rather than a synthesized decoder that would throw on a missing key and — via the
/// store's `try? decode` — silently zero the shipped counters.
struct ConnectionTelemetryTests {

    /// MIGRATION GUARD: a blob persisted before `windowStart` existed (no such key) must upgrade in
    /// place — the shipped connect/uptime/disconnect/reconcile counters MUST survive, not reset to
    /// zero, and `windowStart` reads nil rather than throwing.
    @Test func legacyBlobWithoutWindowStartDecodesAndPreservesCounters() throws {
        let old = #"""
            {"connectCount":3,"totalUptimeSeconds":600,"disconnects":{"btOff":2},
             "reconcile":{"delivered":1},"commandLatency":{"lt500ms":1}}
            """#
        let t = try JSONDecoder().decode(ConnectionTelemetry.self, from: Data(old.utf8))
        #expect(t.connectCount == 3)
        #expect(t.totalUptimeSeconds == 600)
        #expect(t.disconnects["btOff"] == 2)
        #expect(t.reconcile["delivered"] == 1)
        #expect(t.commandLatency["lt500ms"] == 1)
        #expect(t.windowStart == nil)
    }

    /// A blob that DOES carry `windowStart` decodes it back out unchanged (round-trip).
    @Test func windowStartRoundTripsThroughEncodeDecode() throws {
        let original = ConnectionTelemetry(connectCount: 1, windowStart: Date(timeIntervalSince1970: 1_000_000))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionTelemetry.self, from: data)
        #expect(decoded.windowStart == original.windowStart)
        #expect(decoded.connectCount == 1)
    }

    // MARK: - Canonical latency bucket order

    /// The canonical order is fast→slow — NOT the alphabetical sort the house dictionary-row pattern
    /// would produce (`ge4s, lt1s, lt250ms, lt2s, lt4s, lt500ms, timeout`).
    @Test func latencyBucketOrderIsFastToSlow() {
        #expect(
            ConnectionTelemetry.latencyBucketOrder == [
                "lt250ms", "lt500ms", "lt1s", "lt2s", "lt4s", "ge4s", "timeout"
            ])
    }

    /// The canonical order contains exactly the seven tokens `latencyBucket` + `timeoutBucket` can
    /// produce — no more, no fewer, no duplicates.
    @Test func latencyBucketOrderContainsExactlyTheProducibleTokens() {
        let producible: Set<String> = Set(
            [0.0, 0.3, 0.6, 1.5, 3.0, 30.0].map(ConnectionTelemetry.latencyBucket)
                + [ConnectionTelemetry.timeoutBucket])
        #expect(Set(ConnectionTelemetry.latencyBucketOrder) == producible)
        #expect(ConnectionTelemetry.latencyBucketOrder.count == 7)
    }
}
